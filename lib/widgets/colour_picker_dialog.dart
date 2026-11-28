import 'package:flutter/material.dart';

/// A colour choice, plus opacity when the caller offers it.
class ColourPick {
  const ColourPick({required this.color, this.opacity});

  final Color color;

  /// Null when the caller didn't offer an opacity control.
  final double? opacity;
}

/// High-contrast presets chosen for legibility over farm imagery in daylight.
/// A fixed palette beats a wheel here: it's one tap with gloves on, and it
/// keeps the map readable instead of letting it become a paint set.
const List<Color> kColourPresets = <Color>[
  Colors.white,
  Colors.black,
  Colors.yellow,
  Colors.amber,
  Colors.orange,
  Colors.deepOrange,
  Colors.red,
  Colors.pinkAccent,
  Colors.purpleAccent,
  Colors.indigoAccent,
  Colors.blue,
  Colors.lightBlueAccent,
  Colors.cyanAccent,
  Colors.tealAccent,
  Colors.green,
  Colors.lightGreenAccent,
  Colors.limeAccent,
  Colors.brown,
  Colors.blueGrey,
  Colors.grey,
];

/// Palette + optional opacity slider. Returns null when cancelled.
Future<ColourPick?> showColourPicker({
  required BuildContext context,
  required String title,
  required Color color,
  double? opacity,
  double minOpacity = 0.05,
}) {
  return showDialog<ColourPick>(
    context: context,
    builder: (ctx) {
      var picked = color;
      var alpha = (opacity ?? 1.0).clamp(minOpacity, 1.0);

      final scheme = Theme.of(ctx).colorScheme;

      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in kColourPresets)
                        InkResponse(
                          onTap: () => setLocal(() => picked = c),
                          radius: 22,
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: picked == c
                                    ? scheme.primary
                                    : Colors.black26,
                                width: picked == c ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (opacity != null) ...[
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Text('Opacity'),
                        const Spacer(),
                        Text('${(alpha * 100).round()}%'),
                      ],
                    ),
                    Slider(
                      value: alpha,
                      min: minOpacity,
                      max: 1.0,
                      divisions: 19,
                      label: '${(alpha * 100).round()}%',
                      onChanged: (v) => setLocal(() => alpha = v),
                    ),
                    Text(
                      'Preview',
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: 26,
                      decoration: BoxDecoration(
                        color: picked.withValues(alpha: alpha),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  ctx,
                  ColourPick(
                    color: picked,
                    opacity: opacity == null ? null : alpha,
                  ),
                ),
                child: const Text('Use'),
              ),
            ],
          );
        },
      );
    },
  );
}
