import 'dart:convert';
import 'dart:io' as io;

import 'package:downloadsfolder/downloadsfolder.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/job.dart';
import 'job_store.dart';

class BackupInfo {
  final String path;
  final DateTime createdAt;
  final int jobCount;
  final bool hasFarmJson;

  BackupInfo({
    required this.path,
    required this.createdAt,
    required this.jobCount,
    required this.hasFarmJson,
  });
}

class BackupCreateResult {
  final String internalPath;
  final String? downloadsFileName;

  const BackupCreateResult({
    required this.internalPath,
    this.downloadsFileName,
  });

  String get userMessage => downloadsFileName != null
      ? 'Backup saved to Downloads: $downloadsFileName'
      : 'Backup saved: ${internalPath.split('/').last.split('\\').last}';
}

class BackupStore {
  static const _format = 'pasturepath-backup';
  static const _version = 1;

  static const _settingsKeys = [
    'units',
    'width',
    'offset',
    'gpsSmoothness',
    'gpsLateralOffset',
    'hitchToAxle',
    'drawbarLength',
    'boomLateralOffset',
    'selectedToolPresetName',
    'satellite',
    'themeMode',
    'gpsInputMode',
    'gpsBaudRate',
    'gpsPreferredVid',
    'gpsPreferredPid',
  ];

  static Future<String> backupsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = io.Directory('${docs.path}/backups');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  static String _internalBackupFileName(DateTime when) {
    final y = when.year.toString().padLeft(4, '0');
    final m = when.month.toString().padLeft(2, '0');
    final d = when.day.toString().padLeft(2, '0');
    final h = when.hour.toString().padLeft(2, '0');
    final min = when.minute.toString().padLeft(2, '0');
    final s = when.second.toString().padLeft(2, '0');
    return 'pasturepath-backup-$y$m$d-$h$min$s.json';
  }

  /// User-visible name in Downloads: "PasturePath backup YYYY-MM-DD HH-mm-ss.json"
  static String visibleBackupFileName(DateTime when) {
    final y = when.year.toString().padLeft(4, '0');
    final m = when.month.toString().padLeft(2, '0');
    final d = when.day.toString().padLeft(2, '0');
    final h = when.hour.toString().padLeft(2, '0');
    final min = when.minute.toString().padLeft(2, '0');
    final s = when.second.toString().padLeft(2, '0');
    return 'PasturePath backup $y-$m-$d $h-$min-$s.json';
  }

  /// Creates a full local restore point and copies it to the phone Downloads folder.
  static Future<BackupCreateResult> createBackup({
    required Map<String, dynamic> settings,
    String? farmJsonText,
  }) async {
    final now = DateTime.now();
    final jobs = <Map<String, dynamic>>[];
    for (final path in await JobStore.listJobFiles()) {
      final base = path.split('/').last.split('\\').last;
      final txt = await io.File(path).readAsString();
      jobs.add({
        'fileName': base,
        'data': jsonDecode(txt),
      });
    }

    final payload = {
      'format': _format,
      'version': _version,
      'createdAt': now.toIso8601String(),
      'settings': settings,
      if (farmJsonText != null) 'farmJson': farmJsonText,
      'jobs': jobs,
    };

    final internalPath = '${await backupsDir()}/${_internalBackupFileName(now)}';
    await io.File(internalPath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );

    String? downloadsName;
    try {
      final visibleName = visibleBackupFileName(now);
      final copied = await copyFileIntoDownloadFolder(internalPath, visibleName);
      if (copied == true) {
        downloadsName = visibleName;
      }
    } catch (_) {
      // Internal backup still available if Downloads copy fails.
    }

    return BackupCreateResult(
      internalPath: internalPath,
      downloadsFileName: downloadsName,
    );
  }

  static Future<void> _collectBackupsFromDir(
    String dirPath,
    List<BackupInfo> out,
  ) async {
    final dir = io.Directory(dirPath);
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is! io.File || !entity.path.endsWith('.json')) continue;
      try {
        final data = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        if (data['format'] != _format) continue;
        final created =
            DateTime.tryParse(data['createdAt'] as String? ?? '') ?? entity.lastModifiedSync();
        final jobs = (data['jobs'] as List?) ?? const [];
        out.add(BackupInfo(
          path: entity.path,
          createdAt: created,
          jobCount: jobs.length,
          hasFarmJson: data['farmJson'] != null,
        ));
      } catch (_) {
        continue;
      }
    }
  }

  static Future<List<BackupInfo>> listBackups() async {
    final out = <BackupInfo>[];
    await _collectBackupsFromDir(await backupsDir(), out);

    try {
      final downloads = await getDownloadDirectory();
      await _collectBackupsFromDir(downloads.path, out);
    } catch (_) {}

    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final seen = <String>{};
    return out.where((b) {
      final key = '${b.createdAt.toIso8601String()}|${b.jobCount}|${b.hasFarmJson}';
      if (seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();
  }

  static Future<BackupInfo> readInfo(String path) async {
    final data = jsonDecode(await io.File(path).readAsString()) as Map<String, dynamic>;
    _validate(data);
    final jobs = (data['jobs'] as List?) ?? const [];
    return BackupInfo(
      path: path,
      createdAt: DateTime.parse(data['createdAt'] as String),
      jobCount: jobs.length,
      hasFarmJson: data['farmJson'] != null,
    );
  }

  static void _validate(Map<String, dynamic> data) {
    if (data['format'] != _format) {
      throw FormatException('Not a PasturePath backup file');
    }
    final version = data['version'];
    if (version is! num || version > _version) {
      throw FormatException('Unsupported backup version');
    }
  }

  /// Restores jobs, farm JSON, and settings from a backup file.
  static Future<BackupInfo> restoreBackup(String backupPath) async {
    final data = jsonDecode(await io.File(backupPath).readAsString()) as Map<String, dynamic>;
    _validate(data);

    final prefs = await SharedPreferences.getInstance();
    final settings = (data['settings'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final key in _settingsKeys) {
      if (!settings.containsKey(key)) continue;
      final v = settings[key];
      if (v is String) {
        await prefs.setString(key, v);
      } else if (v is bool) {
        await prefs.setBool(key, v);
      } else if (v is int) {
        await prefs.setInt(key, v);
      } else if (v is double) {
        await prefs.setDouble(key, v);
      } else if (v is num) {
        if (key == 'headingDashed' || key == 'satellite') {
          await prefs.setBool(key, v != 0);
        } else if (key == 'gpsBaudRate' ||
            key == 'gpsPreferredVid' ||
            key == 'gpsPreferredPid' ||
            key == 'overlayColor' ||
            key == 'guidanceColor' ||
            key == 'headingColor' ||
            key == 'swathColor') {
          await prefs.setInt(key, v.toInt());
        } else {
          await prefs.setDouble(key, v.toDouble());
        }
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    final farmPath = '${docs.path}/farm.json';
    final farmJson = data['farmJson'];
    if (farmJson is String && farmJson.isNotEmpty) {
      await io.File(farmPath).writeAsString(farmJson, flush: true);
      await prefs.setString('farmJsonPath', farmPath);
    } else {
      final farmFile = io.File(farmPath);
      if (await farmFile.exists()) await farmFile.delete();
      await prefs.remove('farmJsonPath');
    }

    final jobsRoot = io.Directory(await JobStore.jobsDir());
    if (await jobsRoot.exists()) {
      await jobsRoot.delete(recursive: true);
    }
    await jobsRoot.create(recursive: true);

    final jobs = (data['jobs'] as List?) ?? const [];
    for (final entry in jobs) {
      if (entry is! Map) continue;
      final name = entry['fileName']?.toString();
      final jobData = entry['data'];
      if (name == null || name.isEmpty || jobData == null) continue;
      if (jobData is! Map) continue;
      final jobPath = '${jobsRoot.path}/$name';
      final jobMap = Map<String, dynamic>.from(jobData);
      await io.File(jobPath).writeAsString(
        jsonEncode(jobMap),
        flush: true,
      );
      // Sidecar meta so History does not re-parse full paths on first open.
      try {
        final job = SavedJob.fromJson(jobMap);
        final summary = JobFileSummary.fromSavedJob(job, jobPath);
        await io.File(JobStore.metaPathFor(jobPath)).writeAsString(
          jsonEncode(summary.toJson()),
          flush: true,
        );
      } catch (_) {
        // Meta is best-effort; listJobSummaries can still migrate later.
      }
    }

    return BackupInfo(
      path: backupPath,
      createdAt: DateTime.parse(data['createdAt'] as String),
      jobCount: jobs.length,
      hasFarmJson: farmJson is String && farmJson.isNotEmpty,
    );
  }
}
