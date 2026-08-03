import 'dart:convert';
import 'dart:io' as io;

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

Map<String, dynamic> _summaryMapFromJobJson(Map<String, dynamic> j) {
  final hasSaved = j['hasSavedSwathWidth'] == true ||
      j['swathWidthSetting'] != null;
  return {
    'id': j['id'],
    'startedAt': j['startedAt'],
    'endedAt': j['endedAt'],
    'paddockNames': j['paddockNames'],
    'totalHa': j['totalHa'],
    'avgSpeedKph': j['avgSpeedKph'],
    'swathWidthM': j['swathWidthM'],
    'pathDistanceM': j['pathDistanceM'] ?? 0,
    'swathWidthSetting': j['swathWidthSetting'],
    'unitsAtSave': j['unitsAtSave'],
    'hasSavedSwathWidth': hasSaved,
  };
}

/// List job summaries from disk on a background isolate (writes .meta.json for legacy jobs).
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
    if (await io.File(metaPath).exists()) {
      final txt = await io.File(metaPath).readAsString();
      summary = Map<String, dynamic>.from(jsonDecode(txt) as Map<String, dynamic>);
    } else {
      final txt = await io.File(jobPath).readAsString();
      final jobJson = jsonDecode(txt) as Map<String, dynamic>;
      summary = _summaryMapFromJobJson(jobJson);
      await io.File(metaPath).writeAsString(jsonEncode(summary), flush: true);
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
