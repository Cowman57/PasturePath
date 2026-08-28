import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/paddock_work_list.dart';

class PaddockWorkListStore {
  static const _key = 'paddockWorkList';

  static Future<PaddockWorkList> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return PaddockWorkList();
    try {
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        return PaddockWorkList.fromJson(data);
      }
      if (data is Map) {
        return PaddockWorkList.fromJson(data.cast<String, dynamic>());
      }
    } catch (_) {}
    return PaddockWorkList();
  }

  static Future<void> save(PaddockWorkList list) async {
    final p = await SharedPreferences.getInstance();
    if (list.isEmpty) {
      await p.remove(_key);
      return;
    }
    await p.setString(_key, jsonEncode(list.toJson()));
  }
}
