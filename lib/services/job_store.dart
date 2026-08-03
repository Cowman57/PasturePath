import 'dart:convert';
import 'dart:io' as io;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/job.dart';
import 'job_save_isolate.dart';

class JobStore {
  static Future<String> _dir(String name) async {
    final d = await getApplicationDocumentsDirectory();
    final p = io.Directory('${d.path}/$name');
    if (!await p.exists()) await p.create(recursive: true);
    return p.path;
  }

  static Future<String> jobsDir() => _dir('jobs');
  static Future<String> exportsDir() => _dir('exports');

  static Future<List<String>> listJobFiles() async {
    final root = await jobsDir();
    final items = await io.Directory(root).list(followLinks: false).toList();
    final files = items
        .whereType<io.File>()
        .where((f) => f.path.endsWith('.json') && !f.path.endsWith('.meta.json'))
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files.map((f) => f.path).toList();
  }

  static String metaPathFor(String jobJsonPath) {
    if (jobJsonPath.endsWith('.json')) {
      return '${jobJsonPath.substring(0, jobJsonPath.length - 5)}.meta.json';
    }
    return '$jobJsonPath.meta.json';
  }

  static Future<void> save(SavedJob job) async {
    final dir = await jobsDir();
    final safe = job.id.replaceAll('/', '-');
    final path = '$dir/$safe.json';
    final metaPath = metaPathFor(path);
    final summary = JobFileSummary.fromSavedJob(job, path);
    // Write on the main isolate — background compute can hang on some Android devices.
    await writeJobFileStringsIsolate({
      'jobPath': path,
      'metaPath': metaPath,
      'jobJson': jsonEncode(job.toJson()),
      'metaJson': jsonEncode(summary.toJson()),
    });
  }

  static Future<JobFileSummary> readSummary(String filePath) async {
    final meta = io.File(metaPathFor(filePath));
    if (await meta.exists()) {
      final txt = await meta.readAsString();
      return JobFileSummary.fromJson(filePath, jsonDecode(txt) as Map<String, dynamic>);
    }
    final job = await read(filePath);
    return JobFileSummary.fromSavedJob(job, filePath);
  }

  static Future<List<JobFileSummary>> listJobSummaries() async {
    final dir = await jobsDir();
    final maps = await listJobSummariesIsolate(dir);
    return [
      for (final m in maps)
        JobFileSummary.fromJson(
          m['filePath'] as String,
          Map<String, dynamic>.from(m)..remove('filePath'),
        ),
    ];
  }

  static Future<SavedJob> read(String filePath) async {
    final txt = await io.File(filePath).readAsString();
    return SavedJob.fromJson(jsonDecode(txt) as Map<String, dynamic>);
  }

  static Future<void> delete(String filePath) async {
    final f = io.File(filePath);
    if (await f.exists()) {
      await f.delete();
    }
    final meta = io.File(metaPathFor(filePath));
    if (await meta.exists()) {
      await meta.delete();
    }
  }

  static Future<int> nextSequenceForDay(DateTime day) async {
    final files = await listJobFiles();
    final key = _dayKey(day);
    int maxN = 0;
    for (final p in files) {
      final base = p.split('/').last.split('\\').last;
      if (!base.startsWith(key)) continue;
      final ix = base.indexOf('Job ');
      if (ix < 0) continue;
      final nStr = base.substring(ix + 4).split('.').first;
      final n = int.tryParse(nStr) ?? 0;
      if (n > maxN) maxN = n;
    }
    return maxN + 1;
  }

  static String dayTitle(DateTime d, int n) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yy = (d.year % 100).toString().padLeft(2, '0');
    return '$dd/$mm/$yy Job $n';
  }

  static String _dayKey(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yy = (d.year % 100).toString().padLeft(2, '0');
    return '$dd-$mm-$yy';
  }

  // ---------- Exporting ----------

  static Future<String> _uniqueExportPath(String baseName) async {
    final dir = await exportsDir();
    var path = '$dir/$baseName';
    var f = io.File(path);
    int k = 2;
    while (await f.exists()) {
      final parts = baseName.split('.');
      final ext = parts.length > 1 ? '.${parts.last}' : '';
      final stem = ext.isEmpty ? baseName : baseName.substring(0, baseName.length - ext.length);
      path = '$dir/${stem}-$k$ext';
      f = io.File(path);
      k++;
    }
    return path;
  }

  static String _fmtIso(DateTime t) {
    // GPX prefers UTC ISO
    return t.toUtc().toIso8601String();
  }

  static Future<String> exportGpx(List<String> jobFilePaths) async {
    final now = DateTime.now();
    final base = 'jobs-${now.millisecondsSinceEpoch}.gpx';
    final out = await _uniqueExportPath(base);

    final b = StringBuffer();
    b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    b.writeln('<gpx version="1.1" creator="TractorGPS" xmlns="http://www.topografix.com/GPX/1/1">');

    for (final path in jobFilePaths) {
      final job = await read(path);
      b.writeln('  <trk>');
      b.writeln('    <name>${_xml(job.id)}</name>');
      b.writeln('    <trkseg>');
      for (final p in job.path) {
        b.writeln('      <trkpt lat="${p.latitude}" lon="${p.longitude}"><time>${_fmtIso(job.startedAt)}</time></trkpt>');
      }
      b.writeln('    </trkseg>');
      b.writeln('  </trk>');
    }

    b.writeln('</gpx>');
    await io.File(out).writeAsString(b.toString(), flush: true);
    return out;
  }

  static Future<String> exportGeoJson(List<String> jobFilePaths) async {
    final now = DateTime.now();
    final base = 'jobs-${now.millisecondsSinceEpoch}.geojson';
    final out = await _uniqueExportPath(base);

    final feats = <Map<String, dynamic>>[];
    for (final p in jobFilePaths) {
      final job = await read(p);
      final coords = job.path.map((e) => [e.longitude, e.latitude]).toList();
      feats.add({
        'type': 'Feature',
        'properties': {
          'id': job.id,
          'startedAt': job.startedAt.toIso8601String(),
          'endedAt': job.endedAt.toIso8601String(),
          'totalHa': job.totalHa,
          'avgSpeedKph': job.avgSpeedKph,
          'paddocks': job.paddockNames,
        },
        'geometry': {
          'type': 'LineString',
          'coordinates': coords,
        }
      });
    }

    final fc = {'type': 'FeatureCollection', 'features': feats};
    await io.File(out).writeAsString(const JsonEncoder.withIndent('  ').convert(fc), flush: true);
    return out;
  }

  static Future<void> shareFile(String path) async {
    await Share.shareXFiles([XFile(path)]);
  }

  static String _xml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
