import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

/// Write pre-encoded JSON strings to job + meta files on a background isolate.
Future<void> writeJobFileStringsIsolate(Map<String, String> payload) async {
  final jobPath = payload['jobPath']!;
  final metaPath = payload['metaPath']!;
  await io.File(jobPath).writeAsString(payload['jobJson']!, flush: true);
  await io.File(metaPath).writeAsString(payload['metaJson']!, flush: true);
  if (!await io.File(jobPath).exists()) {
    throw StateError('Job file was not written: $jobPath');
  }
}

/// Encode and write job + meta JSON on a background isolate.
Future<void> writeJobFilesIsolate(Map<String, dynamic> payload) async {
  final jobJson = jsonEncode(payload['job'] as Map<String, dynamic>);
  final metaJson = jsonEncode(payload['meta'] as Map<String, dynamic>);
  await writeJobFileStringsIsolate({
    'jobPath': payload['jobPath'] as String,
    'metaPath': payload['metaPath'] as String,
    'jobJson': jobJson,
    'metaJson': metaJson,
  });
}

String _metaPathFor(String jobJsonPath) {
  if (jobJsonPath.endsWith('.json')) {
    return '${jobJsonPath.substring(0, jobJsonPath.length - 5)}.meta.json';
  }
  return '$jobJsonPath.meta.json';
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371000.0;
  final p1 = lat1 * math.pi / 180.0;
  final p2 = lat2 * math.pi / 180.0;
  final dphi = (lat2 - lat1) * math.pi / 180.0;
  final dl = (lon2 - lon1) * math.pi / 180.0;
  final s = math.sin(dphi / 2) * math.sin(dphi / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * R * math.asin(math.min(1.0, math.sqrt(s)));
}

/// Path length from job JSON `path` array.
double _pathGeomM(dynamic rawPath) {
  if (rawPath is! List || rawPath.length < 2) return 0;
  var total = 0.0;
  for (var i = 1; i < rawPath.length; i++) {
    final a = rawPath[i - 1];
    final b = rawPath[i];
    if (a is! Map || b is! Map) continue;
    final lat1 = (a['lat'] as num?)?.toDouble();
    final lon1 = (a['lng'] as num?)?.toDouble();
    final lat2 = (b['lat'] as num?)?.toDouble();
    final lon2 = (b['lng'] as num?)?.toDouble();
    if (lat1 == null || lon1 == null || lat2 == null || lon2 == null) continue;
    total += _haversineM(lat1, lon1, lat2, lon2);
  }
  return total;
}

/// Match [sanitizeAppliedPathDistanceM] without importing Flutter geometry.
double _sanitizePathDistanceM(double storedM, dynamic rawPath) {
  final geom = _pathGeomM(rawPath);
  if (storedM <= 0) return geom;
  if (geom <= 0) return storedM;
  if (storedM > geom * 1.35) return geom;
  return storedM;
}

Map<String, dynamic> _summaryMapFromJobJson(Map<String, dynamic> j) {
  final hasSaved = j['hasSavedSwathWidth'] == true ||
      j['swathWidthSetting'] != null;
  final rawStored = (j['pathDistanceM'] as num?)?.toDouble() ?? 0;
  final pathDist = _sanitizePathDistanceM(rawStored, j['path']);
  return {
    'id': j['id'],
    'startedAt': j['startedAt'],
    'endedAt': j['endedAt'],
    'paddockNames': j['paddockNames'],
    'totalHa': j['totalHa'],
    'avgSpeedKph': j['avgSpeedKph'],
    'swathWidthM': j['swathWidthM'],
    'pathDistanceM': pathDist,
    'swathWidthSetting': j['swathWidthSetting'],
    'unitsAtSave': j['unitsAtSave'],
    'hasSavedSwathWidth': hasSaved,
  };
}

/// List job summaries from disk (always sanitizes pathDistanceM from full job path).
Future<List<Map<String, dynamic>>> listJobSummariesIsolate(String jobsDirPath) async {
  final dir = io.Directory(jobsDirPath);
  if (!await dir.exists()) return [];

  final entries = await dir.list(followLinks: false).toList();
  final jobPaths = entries
      .whereType<io.File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.json') && !p.endsWith('.meta.json'))
      .toList()
    ..sort();

  final rows = <Map<String, dynamic>>[];
  for (final jobPath in jobPaths) {
    final metaPath = _metaPathFor(jobPath);
    Map<String, dynamic> summary;
    try {
      final txt = await io.File(jobPath).readAsString();
      final jobJson = jsonDecode(txt) as Map<String, dynamic>;
      summary = _summaryMapFromJobJson(jobJson);

      // Refresh sidecar so History keeps showing corrected coverage.
      final metaFile = io.File(metaPath);
      var writeMeta = !await metaFile.exists();
      if (!writeMeta) {
        try {
          final old = jsonDecode(await metaFile.readAsString()) as Map;
          final oldDist = (old['pathDistanceM'] as num?)?.toDouble() ?? 0;
          final newDist = (summary['pathDistanceM'] as num?)?.toDouble() ?? 0;
          if ((oldDist - newDist).abs() > 0.5) writeMeta = true;
        } catch (_) {
          writeMeta = true;
        }
      }
      if (writeMeta) {
        await metaFile.writeAsString(jsonEncode(summary), flush: true);
      }
    } catch (_) {
      // Fall back to meta-only if job JSON is unreadable.
      if (await io.File(metaPath).exists()) {
        final txt = await io.File(metaPath).readAsString();
        summary = Map<String, dynamic>.from(jsonDecode(txt) as Map);
      } else {
        continue;
      }
    }
    rows.add({
      'filePath': jobPath,
      ...summary,
    });
  }

  rows.sort((a, b) {
    final aAt = DateTime.parse(a['startedAt'] as String);
    final bAt = DateTime.parse(b['startedAt'] as String);
    return bAt.compareTo(aAt);
  });
  return rows;
}
