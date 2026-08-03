import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tractorgps/models/job.dart';
import 'package:tractorgps/services/job_save_isolate.dart';

void main() {
  test('writeJobFilesIsolate writes job and meta files', () async {
    final dir = await Directory.systemTemp.createTemp('pasturepath_job_save');
    final jobPath = '${dir.path}/test-job.json';
    final metaPath = '${dir.path}/test-job.meta.json';

    final job = {
      'id': 'Test Job',
      'startedAt': DateTime(2026, 1, 1).toIso8601String(),
      'endedAt': DateTime(2026, 1, 1, 1).toIso8601String(),
      'path': [
        {'lat': -37.0, 'lng': 175.0},
        {'lat': -37.001, 'lng': 175.0},
      ],
      'paddockNames': ['North'],
      'totalHa': 5.0,
      'avgSpeedKph': 8.0,
      'pathDistanceM': 100.0,
      'hasSavedSwathWidth': true,
    };
    final meta = JobFileSummary.fromJson(jobPath, {
      'id': 'Test Job',
      'startedAt': job['startedAt'],
      'endedAt': job['endedAt'],
      'paddockNames': ['North'],
      'totalHa': 5.0,
      'avgSpeedKph': 8.0,
      'pathDistanceM': 100.0,
      'hasSavedSwathWidth': true,
    }).toJson();

    await writeJobFilesIsolate({
      'jobPath': jobPath,
      'metaPath': metaPath,
      'job': job,
      'meta': meta,
    });

    expect(await File(jobPath).exists(), isTrue);
    expect(await File(metaPath).exists(), isTrue);
    final decoded = jsonDecode(await File(jobPath).readAsString()) as Map<String, dynamic>;
    expect(decoded['id'], 'Test Job');
    expect((decoded['path'] as List).length, 2);

    await dir.delete(recursive: true);
  });

  test('listJobSummariesIsolate reads meta and migrates legacy jobs', () async {
    final dir = await Directory.systemTemp.createTemp('pasturepath_job_list');
    final jobPath = '${dir.path}/legacy.json';
    await File(jobPath).writeAsString(jsonEncode({
      'id': 'Legacy Job',
      'startedAt': DateTime(2026, 2, 1, 9).toIso8601String(),
      'endedAt': DateTime(2026, 2, 1, 10).toIso8601String(),
      'path': [
        for (int i = 0; i < 100; i++) {'lat': -37.0 + i * 0.00001, 'lng': 175.0},
      ],
      'paddockNames': ['South'],
      'totalHa': 8.0,
      'avgSpeedKph': 6.0,
      'pathDistanceM': 250.0,
      'hasSavedSwathWidth': true,
    }));

    final rows = await listJobSummariesIsolate(dir.path);
    expect(rows.length, 1);
    expect(rows.first['id'], 'Legacy Job');
    expect(await File('${dir.path}/legacy.meta.json').exists(), isTrue);

    final rows2 = await listJobSummariesIsolate(dir.path);
    expect(rows2.length, 1);
    expect(rows2.first['pathDistanceM'], 250.0);

    await dir.delete(recursive: true);
  });

  test('writeJobFileStringsIsolate writes encoded payloads', () async {
    final dir = await Directory.systemTemp.createTemp('pasturepath_job_strings');
    final jobPath = '${dir.path}/strings.json';
    final metaPath = '${dir.path}/strings.meta.json';

    await writeJobFileStringsIsolate({
      'jobPath': jobPath,
      'metaPath': metaPath,
      'jobJson': '{"id":"x","path":[]}',
      'metaJson': '{"id":"x","totalHa":1}',
    });

    expect(await File(jobPath).exists(), isTrue);
    expect(await File(metaPath).exists(), isTrue);
    await dir.delete(recursive: true);
  });

  test('backup-style restore writes .meta.json beside each job', () async {
    final dir = await Directory.systemTemp.createTemp('pasturepath_backup_meta');
    final jobPath = '${dir.path}/03-08-26 Job 1.json';
    final jobMap = {
      'id': '03/08/26 Job 1',
      'startedAt': DateTime(2026, 8, 3, 9).toIso8601String(),
      'endedAt': DateTime(2026, 8, 3, 10).toIso8601String(),
      'path': [
        for (int i = 0; i < 200; i++)
          {'lat': -37.0 + i * 0.00001, 'lng': 175.0},
      ],
      'paddockNames': ['West'],
      'totalHa': 12.0,
      'avgSpeedKph': 9.0,
      'pathDistanceM': 480.0,
      'swathWidthM': 12.0,
      'hasSavedSwathWidth': true,
    };
    await File(jobPath).writeAsString(jsonEncode(jobMap), flush: true);
    final job = SavedJob.fromJson(jobMap);
    final summary = JobFileSummary.fromSavedJob(job, jobPath);
    final metaPath = jobPath.replaceFirst(RegExp(r'\.json$'), '.meta.json');
    await File(metaPath).writeAsString(jsonEncode(summary.toJson()), flush: true);

    expect(await File(metaPath).exists(), isTrue);
    final meta = jsonDecode(await File(metaPath).readAsString()) as Map;
    expect(meta['id'], '03/08/26 Job 1');
    expect(meta['pathDistanceM'], 480.0);
    expect(meta.containsKey('path'), isFalse);

    // list summaries should use meta, not re-parse the 200-point path needlessly
    final rows = await listJobSummariesIsolate(dir.path);
    expect(rows.length, 1);
    expect(rows.first['pathDistanceM'], 480.0);

    await dir.delete(recursive: true);
  });
}
