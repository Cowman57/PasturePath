import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One published release of PasturePath with an installable APK.
class AppUpdate {
  const AppUpdate({
    required this.tag,
    required this.version,
    required this.releaseUrl,
    this.name,
    this.notes,
    this.apkUrl,
    this.apkSizeBytes,
  });

  /// Release tag as published, e.g. `v4.4.0`.
  final String tag;

  /// [tag] without a leading `v`.
  final String version;

  /// Release title.
  final String? name;

  /// Release body (markdown).
  final String? notes;

  /// `html_url` — the release page on GitHub.
  final String releaseUrl;

  /// `browser_download_url` of the first `.apk` asset, if any.
  final String? apkUrl;

  final int? apkSizeBytes;

  /// Human readable APK size, e.g. `42.1 MB`.
  String? get apkSizeLabel {
    final bytes = apkSizeBytes;
    if (bytes == null || bytes <= 0) return null;
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }
}

/// Checks GitHub releases for a newer APK, downloads it and hands it to the
/// Android installer.
class UpdateService {
  static const _releasesApi =
      'https://api.github.com/repos/Cowman57/PasturePath/releases';
  static const _userAgent = 'PasturePath';
  static const _snoozeKey = 'updateSnoozeUntil';

  /// Newest non-draft, non-prerelease build that ships an APK and is newer than
  /// the running app. Returns null when there is nothing to install, and never
  /// throws.
  static Future<AppUpdate?> checkForUpdates() async {
    try {
      final resp = await http.get(
        Uri.parse(_releasesApi),
        headers: const {
          'User-Agent': _userAgent,
          'Accept': 'application/vnd.github+json',
        },
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;

      final data = jsonDecode(resp.body);
      if (data is! List) return null;

      final info = await PackageInfo.fromPlatform();
      final localVersion = info.version;
      final localBuild = info.buildNumber;

      for (final e in data) {
        if (e is! Map) continue;
        if (e['draft'] == true || e['prerelease'] == true) continue;

        final tag = (e['tag_name'] as String?)?.trim() ?? '';
        if (tag.isEmpty) continue;

        String? apkUrl;
        int? apkSize;
        final assets = e['assets'];
        if (assets is List) {
          for (final a in assets) {
            if (a is! Map) continue;
            final assetName = (a['name'] as String?) ?? '';
            if (!assetName.toLowerCase().endsWith('.apk')) continue;
            final url = (a['browser_download_url'] as String?) ?? '';
            if (url.isEmpty) continue;
            apkUrl = url;
            apkSize = (a['size'] as num?)?.toInt();
            break;
          }
        }
        if (apkUrl == null) continue;

        final version = _stripV(tag);
        if (!_isNewer(version, localVersion, localBuild)) continue;

        return AppUpdate(
          tag: tag,
          version: version,
          name: (e['name'] as String?)?.trim(),
          notes: e['body'] as String?,
          releaseUrl: (e['html_url'] as String?) ?? '',
          apkUrl: apkUrl,
          apkSizeBytes: apkSize,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Streams the release APK into `<documents>/updates/` and returns its path.
  /// [onProgress] receives 0..1 when the size is known.
  static Future<String> downloadApk(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final url = update.apkUrl;
    if (url == null || url.isEmpty) {
      throw StateError('No APK published for ${update.version}');
    }

    final docs = await getApplicationDocumentsDirectory();
    final dir = io.Directory('${docs.path}/updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    final path = '${dir.path}/PasturePath-${update.version}.apk';
    final file = io.File(path);
    if (await file.exists()) await file.delete();

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers['User-Agent'] = _userAgent;
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw io.HttpException('Download failed (${resp.statusCode})');
      }

      final total = (resp.contentLength != null && resp.contentLength! > 0)
          ? resp.contentLength
          : update.apkSizeBytes;
      var received = 0;
      onProgress?.call(0);

      final sink = file.openWrite();
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      onProgress?.call(1);
      return path;
    } finally {
      client.close();
    }
  }

  /// Opens the system installer for [path]. Android always asks the user to
  /// confirm, so this cannot install silently.
  static Future<void> installApk(String path) async {
    final result = await OpenFilex.open(
      path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type != ResultType.done) {
      throw StateError(
        result.message.isEmpty ? 'Could not open the installer' : result.message,
      );
    }
  }

  static Future<bool> isSnoozed() async {
    final p = await SharedPreferences.getInstance();
    final until = p.getInt(_snoozeKey);
    if (until == null) return false;
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  static Future<void> snoozeFor(Duration d) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(
      _snoozeKey,
      DateTime.now().add(d).millisecondsSinceEpoch,
    );
  }

  static Future<void> clearSnooze() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_snoozeKey);
  }

  // ---------- version comparison ----------

  static String _stripV(String v) {
    final s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) return s.substring(1);
    return s;
  }

  /// True when [remote] is newer than `localVersion` (then build number).
  static bool _isNewer(String remote, String localVersion, String localBuild) {
    final r = _numericParts(remote);
    final l = _numericParts(localVersion);
    for (var i = 0; i < 3; i++) {
      final a = i < r.length ? r[i] : 0;
      final b = i < l.length ? l[i] : 0;
      if (a != b) return a > b;
    }
    final remoteBuild = _buildPart(remote) ?? 0;
    final local = int.tryParse(localBuild.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    return remoteBuild > local;
  }

  /// `4.4.0` -> `[4, 4, 0]`; tolerates a leading `v` and a `+build` suffix.
  static List<int> _numericParts(String v) {
    final base = _stripV(v).split('+').first;
    return base
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  static int? _buildPart(String v) {
    final ix = v.indexOf('+');
    if (ix < 0) return null;
    return int.tryParse(v.substring(ix + 1).replaceAll(RegExp(r'[^0-9]'), ''));
  }
}
