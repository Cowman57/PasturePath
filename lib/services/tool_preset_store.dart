import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/tool_setup_dimensions.dart';

class ToolPreset {
  const ToolPreset({required this.name, required this.dimensions});

  final String name;
  final ToolSetupDimensions dimensions;

  Map<String, dynamic> toJson() => {
    'name': name,
    ...dimensions.toJson(),
  };

  factory ToolPreset.fromJson(Map<String, dynamic> j) {
    return ToolPreset(
      name: j['name'] as String? ?? 'Preset',
      dimensions: ToolSetupDimensions.fromJson(j),
    );
  }
}

class ToolPresetStore {
  static const _key = 'toolPresetsJson';

  static Future<List<ToolPreset>> list() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => ToolPreset.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAll(List<ToolPreset> presets) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode(presets.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> upsert(ToolPreset preset) async {
    final all = await list();
    final i = all.indexWhere((e) => e.name.toLowerCase() == preset.name.toLowerCase());
    if (i >= 0) {
      all[i] = preset;
    } else {
      all.add(preset);
    }
    all.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    await saveAll(all);
  }

  static Future<void> delete(String name) async {
    final all = await list();
    all.removeWhere((e) => e.name.toLowerCase() == name.toLowerCase());
    await saveAll(all);
  }
}
