import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-tunable map colours, persisted one key per value so a single change
/// doesn't rewrite the whole set.
///
/// Defaults match the app's previous hardcoded appearance, so upgrading changes
/// nothing until the operator edits something.
class MapStyle {
  const MapStyle({
    required this.swathColor,
    required this.swathOpacity,
    required this.trackColor,
    required this.trackOpacity,
    required this.paddockFillColor,
    required this.paddockFillOpacity,
    required this.paddockOutlineColor,
    required this.paddockSelectedColor,
    required this.paddockListedColor,
    required this.paddockDoneColor,
    required this.guidanceColor,
    required this.guidanceOpacity,
    required this.headingColor,
    required this.headingOpacity,
    required this.cursorColor,
  });

  /// Applied swath fill.
  final Color swathColor;
  final double swathOpacity;

  /// Recorded path / track line.
  final Color trackColor;
  final double trackOpacity;

  /// Paddock overlay fill and its plain outline.
  final Color paddockFillColor;
  final double paddockFillOpacity;
  final Color paddockOutlineColor;

  /// Outline tints for the paddock states that used to be hardcoded.
  final Color paddockSelectedColor;
  final Color paddockListedColor;
  final Color paddockDoneColor;

  /// A/B guidance lines and markers.
  final Color guidanceColor;
  final double guidanceOpacity;

  /// Look-ahead heading line.
  final Color headingColor;
  final double headingOpacity;

  /// GPS cursor arrow.
  final Color cursorColor;

  static MapStyle defaults() => MapStyle(
        swathColor: Colors.lightGreenAccent,
        swathOpacity: 0.55,
        trackColor: Colors.white,
        trackOpacity: 0.90,
        paddockFillColor: Colors.green,
        paddockFillOpacity: 0.20,
        paddockOutlineColor: Colors.green,
        paddockSelectedColor: Colors.yellow.shade700,
        paddockListedColor: Colors.orange.shade800,
        paddockDoneColor: Colors.teal.shade700,
        guidanceColor: Colors.white,
        guidanceOpacity: 1.0,
        headingColor: Colors.blueAccent,
        headingOpacity: 0.95,
        cursorColor: Colors.blue.shade700,
      );

  MapStyle copyWith({
    Color? swathColor,
    double? swathOpacity,
    Color? trackColor,
    double? trackOpacity,
    Color? paddockFillColor,
    double? paddockFillOpacity,
    Color? paddockOutlineColor,
    Color? paddockSelectedColor,
    Color? paddockListedColor,
    Color? paddockDoneColor,
    Color? guidanceColor,
    double? guidanceOpacity,
    Color? headingColor,
    double? headingOpacity,
    Color? cursorColor,
  }) {
    return MapStyle(
      swathColor: swathColor ?? this.swathColor,
      swathOpacity: swathOpacity ?? this.swathOpacity,
      trackColor: trackColor ?? this.trackColor,
      trackOpacity: trackOpacity ?? this.trackOpacity,
      paddockFillColor: paddockFillColor ?? this.paddockFillColor,
      paddockFillOpacity: paddockFillOpacity ?? this.paddockFillOpacity,
      paddockOutlineColor: paddockOutlineColor ?? this.paddockOutlineColor,
      paddockSelectedColor: paddockSelectedColor ?? this.paddockSelectedColor,
      paddockListedColor: paddockListedColor ?? this.paddockListedColor,
      paddockDoneColor: paddockDoneColor ?? this.paddockDoneColor,
      guidanceColor: guidanceColor ?? this.guidanceColor,
      guidanceOpacity: guidanceOpacity ?? this.guidanceOpacity,
      headingColor: headingColor ?? this.headingColor,
      headingOpacity: headingOpacity ?? this.headingOpacity,
      cursorColor: cursorColor ?? this.cursorColor,
    );
  }

  // --- persistence -----------------------------------------------------------

  /// Preference keys, also used by the backup whitelist.
  static const String swathColorKey = 'style.swathColor';
  static const String swathOpacityKey = 'style.swathOpacity';
  static const String trackColorKey = 'style.trackColor';
  static const String trackOpacityKey = 'style.trackOpacity';
  static const String paddockFillColorKey = 'style.paddockFillColor';
  static const String paddockFillOpacityKey = 'style.paddockFillOpacity';
  static const String paddockOutlineColorKey = 'style.paddockOutlineColor';
  static const String paddockSelectedColorKey = 'style.paddockSelectedColor';
  static const String paddockListedColorKey = 'style.paddockListedColor';
  static const String paddockDoneColorKey = 'style.paddockDoneColor';
  static const String guidanceColorKey = 'style.guidanceColor';
  static const String guidanceOpacityKey = 'style.guidanceOpacity';
  static const String headingColorKey = 'style.headingColor';
  static const String headingOpacityKey = 'style.headingOpacity';
  static const String cursorColorKey = 'style.cursorColor';

  /// Colour keys are stored as ints (ARGB); the backup restore path needs to
  /// know which numeric preferences are ints rather than doubles.
  static const List<String> colorKeys = <String>[
    swathColorKey,
    trackColorKey,
    paddockFillColorKey,
    paddockOutlineColorKey,
    paddockSelectedColorKey,
    paddockListedColorKey,
    paddockDoneColorKey,
    guidanceColorKey,
    headingColorKey,
    cursorColorKey,
  ];

  static const List<String> opacityKeys = <String>[
    swathOpacityKey,
    trackOpacityKey,
    paddockFillOpacityKey,
    guidanceOpacityKey,
    headingOpacityKey,
  ];

  static Future<MapStyle> load() async {
    final p = await SharedPreferences.getInstance();
    final d = defaults();

    Color readColor(String key, Color fallback) {
      final v = p.getInt(key);
      return v == null ? fallback : Color(v);
    }

    double readOpacity(String key, double fallback) {
      final v = p.getDouble(key);
      return v == null ? fallback : v.clamp(0.0, 1.0);
    }

    return MapStyle(
      swathColor: readColor(swathColorKey, d.swathColor),
      swathOpacity: readOpacity(swathOpacityKey, d.swathOpacity),
      trackColor: readColor(trackColorKey, d.trackColor),
      trackOpacity: readOpacity(trackOpacityKey, d.trackOpacity),
      paddockFillColor: readColor(paddockFillColorKey, d.paddockFillColor),
      paddockFillOpacity:
          readOpacity(paddockFillOpacityKey, d.paddockFillOpacity),
      paddockOutlineColor:
          readColor(paddockOutlineColorKey, d.paddockOutlineColor),
      paddockSelectedColor:
          readColor(paddockSelectedColorKey, d.paddockSelectedColor),
      paddockListedColor:
          readColor(paddockListedColorKey, d.paddockListedColor),
      paddockDoneColor: readColor(paddockDoneColorKey, d.paddockDoneColor),
      guidanceColor: readColor(guidanceColorKey, d.guidanceColor),
      guidanceOpacity: readOpacity(guidanceOpacityKey, d.guidanceOpacity),
      headingColor: readColor(headingColorKey, d.headingColor),
      headingOpacity: readOpacity(headingOpacityKey, d.headingOpacity),
      cursorColor: readColor(cursorColorKey, d.cursorColor),
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(swathColorKey, swathColor.toARGB32());
    await p.setDouble(swathOpacityKey, swathOpacity);
    await p.setInt(trackColorKey, trackColor.toARGB32());
    await p.setDouble(trackOpacityKey, trackOpacity);
    await p.setInt(paddockFillColorKey, paddockFillColor.toARGB32());
    await p.setDouble(paddockFillOpacityKey, paddockFillOpacity);
    await p.setInt(paddockOutlineColorKey, paddockOutlineColor.toARGB32());
    await p.setInt(paddockSelectedColorKey, paddockSelectedColor.toARGB32());
    await p.setInt(paddockListedColorKey, paddockListedColor.toARGB32());
    await p.setInt(paddockDoneColorKey, paddockDoneColor.toARGB32());
    await p.setInt(guidanceColorKey, guidanceColor.toARGB32());
    await p.setDouble(guidanceOpacityKey, guidanceOpacity);
    await p.setInt(headingColorKey, headingColor.toARGB32());
    await p.setDouble(headingOpacityKey, headingOpacity);
    await p.setInt(cursorColorKey, cursorColor.toARGB32());
  }
}
