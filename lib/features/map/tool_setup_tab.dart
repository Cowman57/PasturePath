import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/tool_setup_dimensions.dart';
import '../../services/implement_kinematics.dart';
import '../../services/tool_preset_store.dart';
import '../../widgets/navigation_arrow_icon.dart';

/// Graphic tool / GPS / implement configuration tab.
class ToolSetupTab extends StatefulWidget {
  const ToolSetupTab({
    super.key,
    required this.units,
    required this.lenUnit,
    required this.dimensions,
    required this.gpsSmoothness,
    required this.smoothnessHint,
    required this.presets,
    required this.selectedPresetName,
    required this.onUnitsChanged,
    required this.onDimensionsChanged,
    required this.onGpsSmoothnessChanged,
    required this.onPresetSelected,
    required this.onSavePreset,
    required this.onDeletePreset,
    required this.onSave,
  });

  final String units;
  final String lenUnit;
  final ToolSetupDimensions dimensions;
  final double gpsSmoothness;
  final String smoothnessHint;
  final List<ToolPreset> presets;
  final String? selectedPresetName;
  final ValueChanged<String> onUnitsChanged;
  final ValueChanged<ToolSetupDimensions> onDimensionsChanged;
  final ValueChanged<double> onGpsSmoothnessChanged;
  final ValueChanged<ToolPreset?> onPresetSelected;
  final Future<void> Function(String name) onSavePreset;
  final Future<void> Function(String name) onDeletePreset;
  final VoidCallback onSave;

  @override
  State<ToolSetupTab> createState() => _ToolSetupTabState();
}

class _ToolSetupTabState extends State<ToolSetupTab> {
  Future<void> _editField(ToolDimField field) async {
    final unit = widget.lenUnit;
    final current = field.value(widget.dimensions);
    final ctl = TextEditingController(text: current.toStringAsFixed(1));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(field.title(unit)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (field.hint() != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(field.hint()!, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                  RegExp(field.signed ? r'^-?\d*([.,]\d*)?$' : r'^\d*([.,]\d*)?$'),
                ),
              ],
              decoration: InputDecoration(
                suffixText: unit,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (v) {
                final parsed = double.tryParse(v.replaceAll(',', '.'));
                if (parsed != null) Navigator.pop(ctx, parsed);
              },
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(ctl.text.replaceAll(',', '.'));
              if (parsed != null) Navigator.pop(ctx, parsed);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    widget.onDimensionsChanged(field.apply(widget.dimensions, result));
    widget.onSave();
  }

  Future<void> _promptSavePreset() async {
    final ctl = TextEditingController(text: widget.selectedPresetName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save tool preset'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Preset name',
            hintText: 'e.g. Sprayer, Drill',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final v = ctl.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await widget.onSavePreset(name);
  }

  Future<void> _confirmDeletePreset(ToolPreset preset, {VoidCallback? onDeleted}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${preset.name}"?'),
        content: const Text('This preset will be removed permanently.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await widget.onDeletePreset(preset.name);
    onDeleted?.call();
  }

  void _showPresetPicker() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'Select preset — hold to delete',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Custom'),
                selected: widget.selectedPresetName == null,
                onTap: () {
                  widget.onPresetSelected(null);
                  Navigator.pop(sheetCtx);
                },
              ),
              if (widget.presets.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No saved presets yet. Tap Save to add one.',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                )
              else
                ...widget.presets.map(
                  (p) => ListTile(
                    leading: const Icon(Icons.bookmark_outline),
                    title: Text(p.name),
                    selected: widget.selectedPresetName == p.name,
                    onTap: () {
                      widget.onPresetSelected(p);
                      Navigator.pop(sheetCtx);
                    },
                    onLongPress: () => _confirmDeletePreset(
                      p,
                      onDeleted: () {
                        if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                      },
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.dimensions;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + bottomInset),
      children: [
        const Text('Tool setup', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          'Tap a label on the diagram to edit. Forward is up.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: _showPresetPicker,
                borderRadius: BorderRadius.circular(4),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Preset',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.selectedPresetName ?? 'Custom',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                      Icon(Icons.arrow_drop_down, color: Colors.grey.shade700),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _promptSavePreset,
              icon: const Icon(Icons.bookmark_add_outlined, size: 20),
              label: const Text('Save'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'meters', label: Text('Metric')),
            ButtonSegment(value: 'feet', label: Text('Imperial')),
          ],
          selected: {widget.units},
          onSelectionChanged: (s) => widget.onUnitsChanged(s.first),
        ),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 1.05,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade400),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: _InteractiveDiagram(
                units: widget.units,
                dimensions: d,
                lenUnit: widget.lenUnit,
                onEditField: _editField,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<ImplementMount>(
          segments: const [
            ButtonSegment(
              value: ImplementMount.fixed,
              label: Text('Fixed'),
              icon: Icon(Icons.agriculture, size: 18),
            ),
            ButtonSegment(
              value: ImplementMount.trailed,
              label: Text('Trailed'),
              icon: Icon(Icons.settings_ethernet, size: 18),
            ),
          ],
          selected: {d.mount},
          onSelectionChanged: (s) {
            widget.onDimensionsChanged(d.copyWith(mount: s.first));
            widget.onSave();
          },
        ),
        const SizedBox(height: 8),
        Text(
          d.mount == ImplementMount.trailed
              ? 'Trailed: boom swings wide on corners and when reversing.'
              : 'Fixed: boom locked to travel heading (mounted sprayer etc.).',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 16),
        const Text('GPS display', style: TextStyle(fontWeight: FontWeight.bold)),
        Slider(
          value: widget.gpsSmoothness,
          min: 0,
          max: 1,
          divisions: 20,
          label: widget.gpsSmoothness.toStringAsFixed(2),
          onChanged: widget.onGpsSmoothnessChanged,
        ),
        Text(widget.smoothnessHint, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
      ],
    );
  }
}

class _DiagramLayout {
  _DiagramLayout({
    required this.cx,
    required this.gps,
    required this.pivot,
    required this.axle,
    required this.boomOnLine,
    required this.boomC,
    required this.boomL,
    required this.boomR,
    required this.navIconPx,
    required this.scale,
  });

  final double cx;
  final Offset gps;
  final Offset pivot;
  final Offset axle;
  final Offset boomOnLine;
  final Offset boomC;
  final Offset boomL;
  final Offset boomR;
  final double navIconPx;
  final double scale;

  static const double _navLenM = 5.0;

  static double _toDisplay(double meters, String units) =>
      units == 'feet' ? meters * 3.280839895 : meters;

  factory _DiagramLayout.from(Size size, String units, ToolSetupDimensions d) {
    final cx = size.width * 0.5;
    final navLen = _toDisplay(_navLenM, units);
    final gpsPivot = d.gpsPivotOffset;
    final gpsLat = d.gpsLateralOffset;
    final hitchToAxle = d.hitchToAxle;
    final axleToBoom = d.axleToBoom;
    final boomW = d.width;
    final boomLat = d.boomLateralOffset;

    final reachDown = gpsPivot.abs() + hitchToAxle + axleToBoom + boomW * 0.12;
    final reachAcross = (boomW * 0.5 + gpsLat.abs() + boomLat.abs() + 2.5).clamp(4.0, 30.0);
    final padV = size.height * 0.1;
    final padH = size.width * 0.08;
    final scaleV = (size.height - padV * 2) / math.max(reachDown + navLen * 0.5, 5.0);
    final scaleH = (size.width - padH * 2) / reachAcross;
    final scale = math.min(scaleV, scaleH);

    final navIconPx = navLen * scale;
    final gps = Offset(cx + gpsLat * scale, padV + navIconPx * 0.46);
    final pivot = Offset(gps.dx - gpsLat * scale, gps.dy + gpsPivot * scale);

    final boomHeading = d.mount == ImplementMount.trailed ? 12.0 * math.pi / 180 : 0.0;
    final backX = -math.sin(boomHeading);
    final backY = math.cos(boomHeading);
    final rightX = math.cos(boomHeading);
    final rightY = math.sin(boomHeading);

    final axle = Offset(
      pivot.dx + backX * hitchToAxle * scale,
      pivot.dy + backY * hitchToAxle * scale,
    );
    final boomOnLine = Offset(
      axle.dx + backX * axleToBoom * scale,
      axle.dy + backY * axleToBoom * scale,
    );
    final boomC = Offset(
      boomOnLine.dx + rightX * boomLat * scale,
      boomOnLine.dy + rightY * boomLat * scale,
    );
    final half = boomW * scale * 0.5;
    final boomL = Offset(boomC.dx - rightX * half, boomC.dy - rightY * half);
    final boomR = Offset(boomC.dx + rightX * half, boomC.dy + rightY * half);

    return _DiagramLayout(
      cx: cx,
      gps: gps,
      pivot: pivot,
      axle: axle,
      boomOnLine: boomOnLine,
      boomC: boomC,
      boomL: boomL,
      boomR: boomR,
      navIconPx: navIconPx,
      scale: scale,
    );
  }
}

class _InteractiveDiagram extends StatelessWidget {
  const _InteractiveDiagram({
    required this.units,
    required this.dimensions,
    required this.lenUnit,
    required this.onEditField,
  });

  final String units;
  final ToolSetupDimensions dimensions;
  final String lenUnit;
  final Future<void> Function(ToolDimField field) onEditField;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final layout = _DiagramLayout.from(size, units, dimensions);
        final u = lenUnit;

        String fmt(double v) => '${v.toStringAsFixed(1)}$u';

        return Stack(
          clipBehavior: Clip.none,
          children: [
            CustomPaint(
              size: size,
              painter: _DiagramLinesPainter(layout: layout),
            ),
            Positioned(
              left: layout.gps.dx - layout.navIconPx / 2,
              top: layout.gps.dy - layout.navIconPx / 2,
              width: layout.navIconPx,
              height: layout.navIconPx,
              child: NavigationArrowIcon(size: layout.navIconPx, headingDeg: 0),
            ),
            _chip(
              left: layout.gps.dx + layout.navIconPx * 0.18,
              top: layout.gps.dy - layout.navIconPx * 0.42,
              text: 'GPS',
              onTap: () => onEditField(ToolDimField.gpsLateralOffset),
            ),
            if (dimensions.gpsLateralOffset.abs() > 0.03)
              _chip(
                left: layout.cx - 72,
                top: layout.gps.dy - 12,
                text: 'GPS lat ${fmt(dimensions.gpsLateralOffset)}',
                onTap: () => onEditField(ToolDimField.gpsLateralOffset),
              ),
            _chip(
              left: layout.pivot.dx + 14,
              top: (layout.gps.dy + layout.pivot.dy) / 2 - 10,
              text: 'GPS↔hitch ${fmt(dimensions.gpsPivotOffset)}',
              onTap: () => onEditField(ToolDimField.gpsPivotOffset),
            ),
            _chip(
              left: layout.pivot.dx - 52,
              top: layout.pivot.dy - 10,
              text: 'Hitch',
              onTap: () => onEditField(ToolDimField.hitchToAxle),
            ),
            _chip(
              left: (layout.pivot.dx + layout.axle.dx) / 2 - 58,
              top: (layout.pivot.dy + layout.axle.dy) / 2 - 10,
              text: 'Hitch→axle ${fmt(dimensions.hitchToAxle)}',
              onTap: () => onEditField(ToolDimField.hitchToAxle),
            ),
            if (dimensions.axleToBoom > 0.03 || dimensions.hitchToAxle > 0.03)
              _chip(
                left: layout.axle.dx - 10,
                top: layout.axle.dy - 10,
                text: 'Axle',
                onTap: () => onEditField(ToolDimField.axleToBoom),
              ),
            _chip(
              left: (layout.axle.dx + layout.boomOnLine.dx) / 2 + 10,
              top: (layout.axle.dy + layout.boomOnLine.dy) / 2 - 10,
              text: 'Axle→boom ${fmt(dimensions.axleToBoom)}',
              onTap: () => onEditField(ToolDimField.axleToBoom),
            ),
            _chip(
              left: layout.boomC.dx - 36,
              top: math.max(layout.boomC.dy + 16, layout.boomR.dy + 8),
              text: 'Width ${fmt(dimensions.width)}',
              onTap: () => onEditField(ToolDimField.width),
            ),
            if (dimensions.boomLateralOffset.abs() > 0.03)
              _chip(
                left: layout.boomC.dx + 12,
                top: layout.boomOnLine.dy - 12,
                text: 'Boom lat ${fmt(dimensions.boomLateralOffset)}',
                onTap: () => onEditField(ToolDimField.boomLateralOffset),
              )
            else
              _chip(
                left: layout.boomOnLine.dx - 70,
                top: layout.boomOnLine.dy - 22,
                text: 'Boom lat ${fmt(dimensions.boomLateralOffset)}',
                onTap: () => onEditField(ToolDimField.boomLateralOffset),
              ),
          ],
        );
      },
    );
  }

  Widget _chip({
    required double left,
    required double top,
    required String text,
    required VoidCallback onTap,
  }) {
    return Positioned(
      left: left,
      top: top,
      child: Material(
        color: Colors.white.withValues(alpha: 0.94),
        elevation: 1.5,
        shadowColor: Colors.black26,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(5),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: Colors.blueGrey.shade900,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiagramLinesPainter extends CustomPainter {
  _DiagramLinesPainter({required this.layout});

  final _DiagramLayout layout;

  @override
  void paint(Canvas canvas, Size size) {
    final gps = layout.gps;
    final pivot = layout.pivot;
    final axle = layout.axle;
    final boomOnLine = layout.boomOnLine;

    _dashed(canvas, gps, pivot, Colors.blue.shade700, 2);
    canvas.drawCircle(pivot, 5.5, Paint()..color = Colors.orange.shade800);

    canvas.drawLine(
      pivot,
      axle,
      Paint()
        ..color = Colors.orange.shade700
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(axle, 5, Paint()..color = Colors.orange.shade900);

    if ((axle.dx - boomOnLine.dx).abs() > 0.5 || (axle.dy - boomOnLine.dy).abs() > 0.5) {
      canvas.drawLine(
        axle,
        boomOnLine,
        Paint()
          ..color = Colors.deepOrange.shade400
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    if ((boomOnLine.dx - layout.boomC.dx).abs() > 0.5 ||
        (boomOnLine.dy - layout.boomC.dy).abs() > 0.5) {
      _dashed(canvas, boomOnLine, layout.boomC, Colors.teal.shade700, 1.8);
    }

    canvas.drawLine(
      layout.boomL,
      layout.boomR,
      Paint()
        ..color = Colors.green.shade600
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round,
    );
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Color color, double w) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = w
      ..style = PaintingStyle.stroke;
    const dash = 5.0;
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return;
    final ux = dx / len;
    final uy = dy / len;
    var dist = 0.0;
    while (dist < len) {
      final end = math.min(dist + dash, len);
      canvas.drawLine(
        Offset(a.dx + ux * dist, a.dy + uy * dist),
        Offset(a.dx + ux * end, a.dy + uy * end),
        paint,
      );
      dist += dash * 2;
    }
  }

  @override
  bool shouldRepaint(covariant _DiagramLinesPainter old) => true;
}
