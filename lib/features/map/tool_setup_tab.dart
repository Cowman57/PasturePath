import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/tool_setup_dimensions.dart';
import '../../services/tool_preset_store.dart';

/// Tool / GPS / implement configuration tab.
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
                child: Text(
                  field.hint()!,
                  style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                ),
              ),
            TextField(
              controller: ctl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
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
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
    final unit = widget.lenUnit;

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + bottomInset),
      children: [
        const Text('Tool setup', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
          'Tap a row to edit. Hitch length is distance from GPS to boom centre along travel.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
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
                      Icon(
                        Icons.arrow_drop_down,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
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
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (final field in ToolDimField.values) ...[
                if (field != ToolDimField.values.first) const Divider(height: 1),
                ListTile(
                  title: Text(field.title(unit)),
                  subtitle: field.hint() != null ? Text(field.hint()!) : null,
                  trailing: Text(
                    '${field.value(d).toStringAsFixed(1)} $unit',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  onTap: () => _editField(field),
                ),
              ],
            ],
          ),
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
        Text(
          widget.smoothnessHint,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
