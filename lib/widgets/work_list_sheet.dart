import 'package:flutter/material.dart';

import '../models/paddock.dart';
import '../models/paddock_work_list.dart';
import 'animated_popup.dart';

class WorkListSheetResult {
  const WorkListSheetResult({
    required this.delete,
    required this.unit,
    this.productName,
    this.rate,
  });

  final bool delete;
  final String unit;
  final String? productName;
  final double? rate;
}

Future<WorkListSheetResult?> showWorkListSheet({
  required BuildContext context,
  required PaddockWorkList list,
  required List<Paddock> paddocks,
  required String Function(double ha) areaText,
  required void Function(String name) onRemovePaddock,
  String? hintProductName,
  String? hintRate,
  String? hintUnit,
}) {
  return showFadeModalBottomSheet<WorkListSheetResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _WorkListSheet(
      list: list,
      paddocks: paddocks,
      areaText: areaText,
      onRemovePaddock: onRemovePaddock,
      hintProductName: hintProductName,
      hintRate: hintRate,
      hintUnit: hintUnit,
    ),
  );
}

class _WorkListSheet extends StatefulWidget {
  const _WorkListSheet({
    required this.list,
    required this.paddocks,
    required this.areaText,
    required this.onRemovePaddock,
    this.hintProductName,
    this.hintRate,
    this.hintUnit,
  });

  final PaddockWorkList list;
  final List<Paddock> paddocks;
  final String Function(double ha) areaText;
  final void Function(String name) onRemovePaddock;
  final String? hintProductName;
  final String? hintRate;
  final String? hintUnit;

  @override
  State<_WorkListSheet> createState() => _WorkListSheetState();
}

class _WorkListSheetState extends State<_WorkListSheet> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _rateCtrl;
  late String _unit;

  @override
  void initState() {
    super.initState();
    final existingName = widget.list.productName?.trim();
    _nameCtrl = TextEditingController(
      text: (existingName != null && existingName.isNotEmpty)
          ? existingName
          : '',
    );
    final rate = widget.list.targetRatePerHa;
    _rateCtrl = TextEditingController(
      text: rate != null
          ? rate.toStringAsFixed(0)
          : (widget.hintRate ?? ''),
    );
    _unit = rate != null
        ? widget.list.unit
        : (widget.hintUnit ?? widget.list.unit);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rateCtrl.dispose();
    super.dispose();
  }

  Paddock? _paddockNamed(String name) {
    for (final p in widget.paddocks) {
      if (p.name == name) return p;
    }
    return null;
  }

  WorkListSheetResult _result({required bool delete}) {
    final name = _nameCtrl.text.trim();
    final rate = double.tryParse(_rateCtrl.text.trim());
    return WorkListSheetResult(
      delete: delete,
      unit: _unit,
      productName: name.isEmpty ? null : name,
      rate: (rate != null && rate > 0) ? rate : widget.list.targetRatePerHa,
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    final totalHa = list.totalHa(widget.paddocks);
    final doneHa = list.completedHa(widget.paddocks);
    final remainHa = list.remainingHa(widget.paddocks);
    final typedRate =
        double.tryParse(_rateCtrl.text.trim()) ?? list.targetRatePerHa;
    final expect =
        (typedRate != null && typedRate > 0) ? typedRate * remainHa : null;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Paddock list',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 18,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${list.completedCount}/${list.paddockCount} paddocks · '
            '${widget.areaText(doneHa)} / ${widget.areaText(totalHa)}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'kg', label: Text('kg')),
              ButtonSegment(value: 'L', label: Text('L')),
            ],
            selected: {_unit},
            onSelectionChanged: (s) => setState(() => _unit = s.first),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Product name',
              hintText: widget.hintProductName ?? 'eg. Urea',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _rateCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: _unit == 'L'
                  ? 'Target rate (L/ha)'
                  : 'Target rate (kg/ha)',
              hintText: widget.hintRate ?? 'eg. 80',
            ),
          ),
          if (expect != null) ...[
            const SizedBox(height: 8),
            Text(
              'Expect ${expect.toStringAsFixed(0)} $_unit remaining'
              ' · ${widget.areaText(remainHa)} left',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: list.paddockNames.isEmpty
                ? const Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('No paddocks in the list yet.'),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: list.paddockNames.length,
                    itemBuilder: (ctx, i) {
                      final name = list.paddockNames[i];
                      final match = _paddockNamed(name);
                      final done = list.completedNames.contains(name);
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          done ? Icons.check_circle : Icons.circle_outlined,
                          color: done ? Colors.teal : scheme.primary,
                        ),
                        title: Text(name),
                        subtitle: Text(
                          match == null
                              ? 'Missing from map'
                              : widget.areaText(match.areaHa),
                        ),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            widget.onRemovePaddock(name);
                            setState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, _result(delete: true)),
                child: const Text('Delete list'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _result(delete: false)),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
