import 'package:flutter/material.dart';

import '../models/paddock.dart';
import '../models/paddock_work_list.dart';
import 'animated_popup.dart';

/// Result of the paddock-list sheet.
///
/// Product and rate are handled by the load button, so the only decision here
/// is whether the list itself should be deleted.
class WorkListSheetResult {
  const WorkListSheetResult({required this.delete});

  final bool delete;
}

Future<WorkListSheetResult?> showWorkListSheet({
  required BuildContext context,
  required PaddockWorkList list,
  required List<Paddock> paddocks,
  required String Function(double ha) areaText,
  required void Function(String name) onRemovePaddock,
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
    ),
  );
}

class _WorkListSheet extends StatefulWidget {
  const _WorkListSheet({
    required this.list,
    required this.paddocks,
    required this.areaText,
    required this.onRemovePaddock,
  });

  final PaddockWorkList list;
  final List<Paddock> paddocks;
  final String Function(double ha) areaText;
  final void Function(String name) onRemovePaddock;

  @override
  State<_WorkListSheet> createState() => _WorkListSheetState();
}

class _WorkListSheetState extends State<_WorkListSheet> {
  Paddock? _paddockNamed(String name) {
    for (final p in widget.paddocks) {
      if (p.name == name) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.list;
    final totalHa = list.totalHa(widget.paddocks);
    final doneHa = list.completedHa(widget.paddocks);
    final remainHa = list.remainingHa(widget.paddocks);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Paddocks to do',
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
          if (remainHa > 0) ...[
            const SizedBox(height: 2),
            Text(
              '${widget.areaText(remainHa)} still to do',
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
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
                onPressed: () => Navigator.pop(
                  context,
                  const WorkListSheetResult(delete: true),
                ),
                child: const Text('Delete list'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  const WorkListSheetResult(delete: false),
                ),
                child: const Text('Close'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
