import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

/// File-backed tile cache for offline / weak-signal map use.
class MapTileCache {
  MapTileCache._();

  static io.Directory? _dir;
  static TileProvider? _provider;
  /// Identifies the app and a contact per OSM's tile usage policy. A bare or
  /// generic User-Agent is what gets clients blocked.
  static const _userAgent =
      'PasturePath/4.2.0 (+https://github.com/Cowman57/PasturePath)';

  static Future<io.Directory> cacheDirectory() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final d = io.Directory('${docs.path}/map_tiles');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    return d;
  }

  static Future<TileProvider> provider() async {
    if (_provider != null) return _provider!;
    final dir = await cacheDirectory();
    _provider = _FileCachedTileProvider(cacheDir: dir);
    return _provider!;
  }

  static String tilePath(io.Directory dir, String url) {
    final safe = url
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return '${dir.path}/$safe';
  }

  /// 1x1 transparent PNG, used where a provider has no imagery (HTTP 204/404)
  /// so coverage gaps render as blank instead of throwing per tile.
  static final Uint8List _transparentPixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );

  /// Same blank pixel, for other tile providers that have no imagery to show.
  static Uint8List get transparentPixel => _transparentPixel;

  /// Freshness used when the server sends no usable Cache-Control.
  /// Tiles must never be cached permanently again: a bad response (e.g. a block
  /// page served with HTTP 200) would otherwise be baked in forever.
  static const Duration defaultTtl = Duration(days: 7);

  static String _expiryPath(String tileFilePath) => '$tileFilePath.exp';

  static Duration? _parseMaxAge(String? cacheControl) {
    if (cacheControl == null) return null;
    final m = RegExp(r'max-age\s*=\s*(\d+)').firstMatch(cacheControl);
    final seconds = m == null ? null : int.tryParse(m.group(1)!);
    if (seconds == null) return null;
    // Cap at 30 days so caching stays bounded.
    return Duration(seconds: seconds.clamp(0, 30 * 24 * 3600));
  }

  static Future<bool> _isFresh(String tileFilePath) async {
    try {
      final f = io.File(_expiryPath(tileFilePath));
      if (!await f.exists()) return false;
      final expiry = int.tryParse((await f.readAsString()).trim());
      if (expiry == null) return false;
      return DateTime.now().millisecondsSinceEpoch < expiry;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _writeExpiry(String tileFilePath, Duration ttl) async {
    try {
      await io.File(_expiryPath(tileFilePath)).writeAsString(
        '${DateTime.now().add(ttl).millisecondsSinceEpoch}',
        flush: false,
      );
    } catch (_) {}
  }

  /// True only for real image payloads. Rejects HTML/text error pages that some
  /// servers return with a 200 status.
  static bool looksLikeImage(Uint8List b) {
    if (b.length < 12) return false;
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true; // PNG
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true; // JPEG
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return true; // WebP
    }
    return false;
  }

  /// Deletes every cached tile. Returns the number of files removed.
  static Future<int> clear() async {
    final dir = await cacheDirectory();
    var removed = 0;
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is io.File) {
          try {
            await e.delete();
            removed++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return removed;
  }

  /// Prefetch OSM (or given template) tiles covering [bounds] for [minZoom]–[maxZoom].
  ///
  /// Caps work at [maxTiles]. Returns tiles attempted (not necessarily downloaded).
  /// Call [isCancelled] periodically to abort early.
  static Future<int> prefetchBounds({
    required LatLngBounds bounds,
    required String urlTemplate,
    int minZoom = 13,
    int maxZoom = 16,
    int maxTiles = 2500,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = await cacheDirectory();
    final coords = <({int z, int x, int y})>[];
    outer:
    for (var z = minZoom; z <= maxZoom; z++) {
      final a = _latLngToTile(bounds.north, bounds.west, z);
      final b = _latLngToTile(bounds.south, bounds.east, z);
      final x0 = math.min(a.$1, b.$1);
      final x1 = math.max(a.$1, b.$1);
      final y0 = math.min(a.$2, b.$2);
      final y1 = math.max(a.$2, b.$2);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          coords.add((z: z, x: x, y: y));
          if (coords.length >= maxTiles) break outer;
        }
      }
    }

    final total = coords.length;
    if (total == 0) {
      onProgress?.call(0, 0);
      return 0;
    }

    var done = 0;
    var lastReported = -1;
    void report({bool force = false}) {
      if (!force && done != total && done - lastReported < 8) return;
      lastReported = done;
      onProgress?.call(done, total);
    }

    report(force: true);

    final client = http.Client();
    try {
      const workers = 4;
      var next = 0;

      Future<void> worker() async {
        while (true) {
          if (isCancelled?.call() == true) return;
          final idx = next++;
          if (idx >= coords.length) return;

          final c = coords[idx];
          final url = urlTemplate
              .replaceAll('{z}', '${c.z}')
              .replaceAll('{x}', '${c.x}')
              .replaceAll('{y}', '${c.y}')
              .replaceAll('{s}', 'a');
          final path = tilePath(dir, url);
          final file = io.File(path);
          if (!await file.exists()) {
            try {
              final res = await client
                  .get(
                    Uri.parse(url),
                    headers: {'User-Agent': _userAgent},
                  )
                  .timeout(const Duration(seconds: 8));
              if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
                await file.writeAsBytes(res.bodyBytes, flush: false);
              }
            } catch (_) {
              // Skip failed tile; continue so the bar never hangs on one request.
            }
          }
          done++;
          report();
        }
      }

      await Future.wait(List.generate(workers, (_) => worker()));
      report(force: true);
      return done;
    } finally {
      client.close();
    }
  }

  static (int, int) _latLngToTile(double lat, double lng, int zoom) {
    final n = math.pow(2.0, zoom);
    final x = ((lng + 180.0) / 360.0 * n).floor();
    final latRad = lat * math.pi / 180.0;
    final y = ((1.0 -
                math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) /
                    math.pi) /
            2.0 *
            n)
        .floor();
    return (x.clamp(0, n.toInt() - 1), y.clamp(0, n.toInt() - 1));
  }

  /// Bounds expanded slightly around paddock rings.
  static LatLngBounds? boundsForPaddocks(List<LatLng> points, {double padDeg = 0.008}) {
    if (points.length < 2) return null;
    var n = -90.0, s = 90.0, e = -180.0, w = 180.0;
    for (final p in points) {
      n = math.max(n, p.latitude);
      s = math.min(s, p.latitude);
      e = math.max(e, p.longitude);
      w = math.min(w, p.longitude);
    }
    return LatLngBounds(
      LatLng(s - padDeg, w - padDeg),
      LatLng(n + padDeg, e + padDeg),
    );
  }
}

class _FileCachedTileProvider extends TileProvider {
  _FileCachedTileProvider({required this.cacheDir});

  final io.Directory cacheDir;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    return _CachedTileImage(url: url, filePath: MapTileCache.tilePath(cacheDir, url));
  }
}

class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  const _CachedTileImage({required this.url, required this.filePath});

  final String url;
  final String filePath;

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _CachedTileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final file = io.File(filePath);

    // Serve a fresh, valid cached tile. Anything stale, unparsable or not an
    // image is discarded so a poisoned cache heals itself.
    if (await file.exists() && await MapTileCache._isFresh(filePath)) {
      try {
        final cached = await file.readAsBytes();
        if (MapTileCache.looksLikeImage(cached)) {
          final buffer = await ui.ImmutableBuffer.fromUint8List(cached);
          return await decode(buffer);
        }
      } catch (_) {}
      try {
        await file.delete();
      } catch (_) {}
    }

    final res = await http.get(
      Uri.parse(url),
      headers: {'User-Agent': MapTileCache._userAgent},
    ).timeout(const Duration(seconds: 12));

    // 204/404 means the provider has no imagery here (e.g. OpenAerialMap
    // coverage gaps). Render blank rather than throwing for every tile.
    if (res.statusCode == 204 || res.statusCode == 404) {
      final buffer =
          await ui.ImmutableBuffer.fromUint8List(MapTileCache._transparentPixel);
      return decode(buffer);
    }

    if (res.statusCode != 200) {
      throw StateError('Tile HTTP ${res.statusCode} for $url');
    }

    final contentType = res.headers['content-type'] ?? '';
    final bytes = res.bodyBytes;
    if (!contentType.startsWith('image/') ||
        !MapTileCache.looksLikeImage(bytes)) {
      // Never cache a non-image payload (block pages, HTML errors, ...).
      final buffer =
          await ui.ImmutableBuffer.fromUint8List(MapTileCache._transparentPixel);
      return decode(buffer);
    }

    try {
      await file.writeAsBytes(bytes, flush: false);
      final ttl = MapTileCache._parseMaxAge(res.headers['cache-control']) ??
          MapTileCache.defaultTtl;
      await MapTileCache._writeExpiry(filePath, ttl);
    } catch (_) {}

    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
