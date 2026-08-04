import 'dart:convert';
import 'dart:io' as io;

import 'package:path_provider/path_provider.dart';

import '../models/load_session.dart';

class LoadSessionStore {
  static const _fileName = 'load_sessions.json';

  static Future<String> _filePath() async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}/$_fileName';
  }

  static Future<Map<String, dynamic>> _readRoot() async {
    final path = await _filePath();
    final f = io.File(path);
    if (!await f.exists()) {
      return {'sessions': <dynamic>[], 'openSessionId': null};
    }
    try {
      final data = jsonDecode(await f.readAsString());
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return data.cast<String, dynamic>();
    } catch (_) {}
    return {'sessions': <dynamic>[], 'openSessionId': null};
  }

  static Future<void> _writeRoot(Map<String, dynamic> root) async {
    final path = await _filePath();
    await io.File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(root),
      flush: true,
    );
  }

  static Future<List<LoadSession>> listAll() async {
    final root = await _readRoot();
    final raw = root['sessions'];
    if (raw is! List) return [];
    final out = <LoadSession>[];
    for (final e in raw) {
      if (e is Map) {
        out.add(LoadSession.fromJson(e.cast<String, dynamic>()));
      }
    }
    out.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return out;
  }

  static Future<LoadSession?> openSession() async {
    final root = await _readRoot();
    final openId = root['openSessionId'] as String?;
    if (openId == null || openId.isEmpty) return null;
    final all = await listAll();
    for (final s in all) {
      if (s.id == openId && s.isOpen) return s;
    }
    // Stale open id — clear it.
    root['openSessionId'] = null;
    await _writeRoot(root);
    return null;
  }

  static Future<LoadSession> start({
    required double startQty,
    required double targetRatePerHa,
    required String unit,
    String? productName,
    double? productLoadedKg,
    double? targetProductRatePerHa,
  }) async {
    final existing = await openSession();
    if (existing != null) {
      throw StateError('A product load is already open');
    }
    final now = DateTime.now();
    final name = productName?.trim();
    final session = LoadSession(
      id: 'load-${now.millisecondsSinceEpoch}',
      unit: unit == 'L' ? 'L' : 'kg',
      startQty: startQty,
      currentQty: startQty,
      targetRatePerHa: targetRatePerHa,
      startedAt: now,
      productName: (name != null && name.isNotEmpty) ? name : null,
      productLoadedKg: (unit == 'L' && productLoadedKg != null && productLoadedKg > 0)
          ? productLoadedKg
          : null,
      targetProductRatePerHa:
          (unit == 'L' &&
                  targetProductRatePerHa != null &&
                  targetProductRatePerHa > 0)
              ? targetProductRatePerHa
              : null,
    );
    final root = await _readRoot();
    final sessions = (root['sessions'] is List)
        ? List<dynamic>.from(root['sessions'] as List)
        : <dynamic>[];
    sessions.add(session.toJson());
    root['sessions'] = sessions;
    root['openSessionId'] = session.id;
    await _writeRoot(root);
    return session;
  }

  static Future<LoadSession?> attachJob({
    required String jobId,
    required double appliedHa,
  }) async {
    final open = await openSession();
    if (open == null) return null;
    if (jobId.isEmpty || appliedHa < 0) return open;

    // Avoid duplicate attach of the same job id.
    if (open.jobs.any((j) => j.jobId == jobId)) return open;

    open.jobs.add(LoadSessionJobRef(jobId: jobId, appliedHa: appliedHa));
    await _upsert(open, keepOpen: true);
    return open;
  }

  /// Record a scale reading without ending the load.
  /// Usage since the previous reading is attributed to pending jobs, then
  /// [reading] becomes the new start ([currentQty]).
  static Future<LoadSession> recordReading({required double reading}) async {
    final open = await openSession();
    if (open == null) {
      throw StateError('No open product load');
    }
    if (reading < 0) {
      throw ArgumentError('Reading must be >= 0');
    }
    open.applyReading(reading);
    await _upsert(open, keepOpen: true);
    return open;
  }

  static Future<LoadSession> endLoad({required double endQty}) async {
    final open = await openSession();
    if (open == null) {
      throw StateError('No open product load');
    }
    // Attribute any pending jobs, roll current, then close.
    open.applyReading(endQty);
    final closed = open.copyWith(
      currentQty: endQty,
      endQty: endQty,
      endedAt: DateTime.now(),
      jobs: List<LoadSessionJobRef>.from(open.jobs),
    );
    await _upsert(closed, keepOpen: false);
    return closed;
  }

  /// Cancel an open load without recording an end reading (discards session jobs link).
  static Future<void> cancelOpen() async {
    final open = await openSession();
    if (open == null) return;
    final root = await _readRoot();
    final sessions = (root['sessions'] is List)
        ? List<dynamic>.from(root['sessions'] as List)
        : <dynamic>[];
    sessions.removeWhere((e) => e is Map && e['id'] == open.id);
    root['sessions'] = sessions;
    root['openSessionId'] = null;
    await _writeRoot(root);
  }

  static Future<void> _upsert(LoadSession session, {required bool keepOpen}) async {
    final root = await _readRoot();
    final sessions = (root['sessions'] is List)
        ? List<dynamic>.from(root['sessions'] as List)
        : <dynamic>[];
    final ix = sessions.indexWhere((e) => e is Map && e['id'] == session.id);
    final json = session.toJson();
    if (ix >= 0) {
      sessions[ix] = json;
    } else {
      sessions.add(json);
    }
    root['sessions'] = sessions;
    root['openSessionId'] = keepOpen ? session.id : null;
    await _writeRoot(root);
  }

  /// Product stats by job id — includes measured jobs on an open load, and
  /// all jobs on closed loads.
  static Future<Map<String, JobProductStats>> productStatsByJobId() async {
    final all = await listAll();
    final out = <String, JobProductStats>{};
    for (final s in all) {
      for (final j in s.jobs) {
        // Open load: only jobs that already have a reading.
        if (s.isOpen && !j.hasReading) continue;
        // Closed without any usable amount: skip.
        final carrierAmount = s.amountForJob(j.jobId);
        if (carrierAmount == null) continue;
        final carrierRate = s.rateForJob(j.jobId) ?? s.actualRatePerHa;
        if (carrierRate == null) continue;

        final productAmount = s.productAmountForJob(j.jobId);
        final productRate = s.productRateForJob(j.jobId);
        if (productAmount != null && productRate != null) {
          out[j.jobId] = JobProductStats(
            amount: productAmount,
            ratePerHa: productRate,
            unit: s.unit,
            productName: s.productName,
            carrierAmount: carrierAmount,
            carrierRatePerHa: carrierRate,
          );
        } else {
          out[j.jobId] = JobProductStats(
            amount: carrierAmount,
            ratePerHa: carrierRate,
            unit: s.unit,
            productName: s.productName,
          );
        }
      }
    }
    return out;
  }

  static Future<Map<String, dynamic>> exportForBackup() async {
    return await _readRoot();
  }

  static Future<void> importFromBackup(Map<String, dynamic>? data) async {
    if (data == null) {
      final path = await _filePath();
      final f = io.File(path);
      if (await f.exists()) await f.delete();
      return;
    }
    // Normalize shape.
    final sessions = data['sessions'];
    final root = <String, dynamic>{
      'sessions': sessions is List ? sessions : <dynamic>[],
      'openSessionId': data['openSessionId'],
    };
    await _writeRoot(root);
  }
}
