import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'map_tile_cache.dart';

/// Geographic extent of an imported orthomosaic, in WGS84 degrees.
///
/// Kept as plain doubles (rather than [LatLngBounds]) so it serialises cleanly
/// and stays independent of the map library.
class OrthoBounds {
  const OrthoBounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  final double west;
  final double south;
  final double east;
  final double north;

  LatLngBounds toLatLngBounds() =>
      LatLngBounds(LatLng(south, west), LatLng(north, east));

  Map<String, dynamic> toJson() => {
        'west': west,
        'south': south,
        'east': east,
        'north': north,
      };

  factory OrthoBounds.fromJson(Map<String, dynamic> j) {
    return OrthoBounds(
      west: (j['west'] as num).toDouble(),
      south: (j['south'] as num).toDouble(),
      east: (j['east'] as num).toDouble(),
      north: (j['north'] as num).toDouble(),
    );
  }

  @override
  String toString() => '$west,$south,$east,$north';
}

/// A user-imported drone orthomosaic, stored as a pre-tiled MBTiles file.
///
/// Purely visual: nothing here feeds area, distance, coverage or guidance maths.
class OrthoLayer {
  OrthoLayer({
    required this.id,
    required this.filePath,
    required this.name,
    required this.bounds,
    required this.minZoom,
    required this.maxZoom,
    required this.sizeBytes,
    this.format = '',
    this.enabled = true,
    this.opacity = 1.0,
  });

  final String id;
  final String filePath;
  final String name;
  final OrthoBounds bounds;
  final int minZoom;
  final int maxZoom;
  final int sizeBytes;

  /// Tile image format declared by the file's metadata (png/jpg/webp).
  final String format;

  bool enabled;
  double opacity;

  /// Size in megabytes, for display only.
  double get sizeMb => sizeBytes / (1024 * 1024);

  OrthoLayer copyWith({bool? enabled, double? opacity}) {
    return OrthoLayer(
      id: id,
      filePath: filePath,
      name: name,
      bounds: bounds,
      minZoom: minZoom,
      maxZoom: maxZoom,
      sizeBytes: sizeBytes,
      format: format,
      enabled: enabled ?? this.enabled,
      opacity: opacity ?? this.opacity,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        'name': name,
        'bounds': bounds.toJson(),
        'minZoom': minZoom,
        'maxZoom': maxZoom,
        'sizeBytes': sizeBytes,
        'format': format,
        'enabled': enabled,
        'opacity': opacity,
      };

  factory OrthoLayer.fromJson(Map<String, dynamic> j) {
    return OrthoLayer(
      id: j['id'] as String,
      filePath: j['filePath'] as String,
      name: j['name'] as String? ?? 'Imagery',
      bounds: OrthoBounds.fromJson((j['bounds'] as Map).cast<String, dynamic>()),
      minZoom: (j['minZoom'] as num?)?.toInt() ?? 0,
      maxZoom: (j['maxZoom'] as num?)?.toInt() ?? 19,
      sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
      format: j['format'] as String? ?? '',
      enabled: j['enabled'] as bool? ?? true,
      opacity: (j['opacity'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// Import, persist and read pre-tiled MBTiles orthomosaics.
class OrthoLayerStore {
  OrthoLayerStore._();

  static const String _key = 'orthoLayers';

  /// Open read-only handles, keyed by file path, so a pan doesn't reopen the
  /// database for every tile.
  static final Map<String, Future<sqflite.Database>> _dbFutures =
      <String, Future<sqflite.Database>>{};

  static Future<io.Directory> _layerDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = io.Directory('${docs.path}/ortho_layers');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _sanitiseName(String originalName) {
    var base = originalName
        .replaceAll(RegExp(r'\.mbtiles$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    base = base.replaceAll(RegExp(r'[._]+$'), '');
    if (base.isEmpty) base = 'imagery';
    return base.length > 60 ? base.substring(0, 60) : base;
  }

  /// Never clobbers a previously imported file with the same name.
  static Future<io.File> _uniqueTarget(io.Directory dir, String safeName) async {
    var file = io.File('${dir.path}/$safeName.mbtiles');
    var n = 1;
    while (await file.exists()) {
      n++;
      file = io.File('${dir.path}/$safeName-$n.mbtiles');
    }
    return file;
  }

  /// Copies [sourcePath] into app storage, validates it as MBTiles and returns
  /// the new layer (enabled and fully opaque).
  ///
  /// Throws [FormatException] with a readable message when the file is not a
  /// usable MBTiles archive, and [io.FileSystemException] when it cannot be
  /// copied.
  static Future<OrthoLayer> importFromPickedFile({
    required String sourcePath,
    required String originalName,
  }) async {
    final dir = await _layerDirectory();
    final safeName = _sanitiseName(originalName);
    final target = await _uniqueTarget(dir, safeName);

    // The picker usually hands back a real cached file path; `content://` URIs
    // (some providers) can only be read through their resolved copy.
    var copied = false;
    try {
      final src = io.File(sourcePath);
      if (await src.exists()) {
        await src.copy(target.path);
        copied = true;
      }
    } catch (_) {
      copied = false;
    }
    if (!copied) {
      try {
        final bytes = await io.File(sourcePath).readAsBytes();
        await target.writeAsBytes(bytes, flush: true);
      } catch (e) {
        throw io.FileSystemException(
          'Could not read the selected file. Copy it into local storage '
          '(e.g. Downloads) and import again.',
          sourcePath,
        );
      }
    }

    try {
      return await _readLayer(target, originalName: originalName, safeName: safeName);
    } catch (_) {
      // Don't leave an unusable copy behind.
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      rethrow;
    }
  }

  static Future<OrthoLayer> _readLayer(
    io.File file, {
    required String originalName,
    required String safeName,
  }) async {
    sqflite.Database? db;
    try {
      db = await sqflite.openDatabase(file.path, readOnly: true);

      final meta = <String, String>{};
      final rows = await db.query('metadata', columns: ['name', 'value']);
      for (final r in rows) {
        final k = r['name'];
        final v = r['value'];
        if (k is String && v != null) meta[k.toLowerCase()] = v.toString();
      }
      if (meta.isEmpty) {
        throw const FormatException(
          'This file has no MBTiles metadata table. Re-export it as MBTiles.',
        );
      }

      final bounds = _parseBounds(meta['bounds']);
      final minZoom = int.tryParse((meta['minzoom'] ?? '').trim());
      final maxZoom = int.tryParse((meta['maxzoom'] ?? '').trim());
      if (minZoom == null || maxZoom == null) {
        throw const FormatException(
          'This MBTiles file is missing minzoom/maxzoom. Re-export it with '
          'zoom metadata included.',
        );
      }
      if (minZoom < 0 || maxZoom < minZoom || maxZoom > 30) {
        throw FormatException(
          'This MBTiles file has an unusable zoom range ($minZoom–$maxZoom).',
        );
      }

      final format = (meta['format'] ?? '').trim().toLowerCase();
      if (format.isNotEmpty &&
          !const {'png', 'jpg', 'jpeg', 'webp'}.contains(format)) {
        throw FormatException(
          'Unsupported tile format "$format". Use PNG, JPEG or WebP imagery.',
        );
      }

      // Cheap existence check — no full COUNT(*) scan on a multi-GB file.
      final any = await db.rawQuery('SELECT 1 FROM tiles LIMIT 1');
      if (any.isEmpty) {
        throw const FormatException(
          'This MBTiles file contains no tiles.',
        );
      }

      final declaredName = (meta['name'] ?? '').trim();
      final name = declaredName.isNotEmpty ? declaredName : safeName;

      var size = 0;
      try {
        size = await file.length();
      } catch (_) {}

      return OrthoLayer(
        id: 'ortho_${DateTime.now().microsecondsSinceEpoch}',
        filePath: file.path,
        name: name,
        bounds: bounds,
        minZoom: minZoom,
        maxZoom: maxZoom,
        sizeBytes: size,
        format: format,
      );
    } on FormatException {
      rethrow;
    } on sqflite.DatabaseException catch (e) {
      throw FormatException(
        'Not a readable MBTiles file (${e.toString()}).',
      );
    } finally {
      try {
        await db?.close();
      } catch (_) {}
    }
  }

  static OrthoBounds _parseBounds(String? raw) {
    final parts = (raw ?? '')
        .split(',')
        .map((e) => double.tryParse(e.trim()))
        .toList();
    if (parts.length != 4 || parts.any((e) => e == null)) {
      throw const FormatException(
        'This MBTiles file has no usable bounds metadata '
        '(expected "west,south,east,north").',
      );
    }
    final west = parts[0]!;
    final south = parts[1]!;
    final east = parts[2]!;
    final north = parts[3]!;
    final valid = west >= -180 &&
        east <= 180 &&
        south >= -90 &&
        north <= 90 &&
        west < east &&
        south < north;
    if (!valid) {
      throw FormatException(
        'This MBTiles file has invalid bounds ($raw).',
      );
    }
    return OrthoBounds(west: west, south: south, east: east, north: north);
  }

  /// Persisted layers, with entries whose file has vanished dropped.
  static Future<List<OrthoLayer>> list() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return [];

    final List<dynamic> decoded;
    try {
      final v = jsonDecode(raw);
      if (v is! List) return [];
      decoded = v;
    } catch (_) {
      return [];
    }

    final out = <OrthoLayer>[];
    for (final e in decoded.whereType<Map>()) {
      try {
        final layer = OrthoLayer.fromJson(e.cast<String, dynamic>());
        if (await io.File(layer.filePath).exists()) out.add(layer);
      } catch (_) {
        // Skip a corrupt entry rather than losing the whole list.
      }
    }
    return out;
  }

  static Future<void> saveState(List<OrthoLayer> layers) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _key,
      jsonEncode(layers.map((e) => e.toJson()).toList()),
    );
  }

  /// Deletes the imported file and its record.
  static Future<void> delete(OrthoLayer layer) async {
    await _closeCached(layer.filePath);
    try {
      final f = io.File(layer.filePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}

    final all = await list();
    all.removeWhere((e) => e.id == layer.id);
    await saveState(all);
  }

  static Future<sqflite.Database> _open(String path) async {
    final existing = _dbFutures[path];
    if (existing != null) return existing;
    final future = sqflite.openDatabase(path, readOnly: true);
    _dbFutures[path] = future;
    try {
      return await future;
    } catch (_) {
      _dbFutures.remove(path);
      rethrow;
    }
  }

  static Future<void> _closeCached(String path) async {
    final future = _dbFutures.remove(path);
    if (future == null) return;
    try {
      await (await future).close();
    } catch (_) {}
  }

  /// Raw tile blob for XYZ [z]/[x]/[y], or null when this layer has no imagery
  /// there. Never throws — a missing tile must render as blank, not as an error.
  static Future<Uint8List?> tileBytes(
    OrthoLayer layer,
    int z,
    int x,
    int y,
  ) async {
    if (z < layer.minZoom || z > layer.maxZoom) return null;
    final n = 1 << z;
    if (x < 0 || y < 0 || x >= n || y >= n) return null;

    // MBTiles stores TMS rows (origin bottom-left); flutter_map asks for XYZ.
    final tmsRow = n - 1 - y;

    try {
      final db = await _open(layer.filePath);
      final rows = await db.query(
        'tiles',
        columns: ['tile_data'],
        where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
        whereArgs: [z, x, tmsRow],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final data = rows.first['tile_data'];
      if (data is Uint8List) return data;
      if (data is List<int>) return Uint8List.fromList(data);
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Serves tiles straight out of an imported MBTiles file.
///
/// Missing tiles, out-of-range zooms and unreadable blobs all resolve to a 1x1
/// transparent PNG so the basemap shows through.
class OrthoMbTilesProvider extends TileProvider {
  OrthoMbTilesProvider(this.layer);

  final OrthoLayer layer;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return _OrthoTileImage(
      layer: layer,
      z: coordinates.z,
      x: coordinates.x,
      y: coordinates.y,
    );
  }
}

class _OrthoTileImage extends ImageProvider<_OrthoTileImage> {
  const _OrthoTileImage({
    required this.layer,
    required this.z,
    required this.x,
    required this.y,
  });

  final OrthoLayer layer;
  final int z;
  final int x;
  final int y;

  @override
  Future<_OrthoTileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _OrthoTileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: 'ortho:${layer.id}:$z/$x/$y',
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    Uint8List? bytes;
    try {
      bytes = await OrthoLayerStore.tileBytes(layer, z, x, y);
    } catch (_) {
      bytes = null;
    }
    if (bytes == null || !MapTileCache.looksLikeImage(bytes)) {
      return _decode(decode, MapTileCache.transparentPixel);
    }
    try {
      return await _decode(decode, bytes);
    } catch (_) {
      // Corrupt blob: blank tile instead of a broken-tile marker.
      return _decode(decode, MapTileCache.transparentPixel);
    }
  }

  Future<ui.Codec> _decode(ImageDecoderCallback decode, Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is _OrthoTileImage &&
      other.layer.id == layer.id &&
      other.z == z &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(layer.id, z, x, y);
}
