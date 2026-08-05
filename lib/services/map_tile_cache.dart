import 'dart:async';
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
  static const _userAgent = 'PasturePath/1.0 (farm guidance; offline cache)';

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
    late final Uint8List bytes;
    if (await file.exists()) {
      bytes = await file.readAsBytes();
    } else {
      final res = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': MapTileCache._userAgent},
      ).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        throw StateError('Tile HTTP ${res.statusCode}');
      }
      bytes = res.bodyBytes;
      try {
        await file.writeAsBytes(bytes, flush: false);
      } catch (_) {}
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
