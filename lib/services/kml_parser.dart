import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Result of converting a Google Earth KML/KMZ file into GeoJSON.
class KmlImportResult {
  const KmlImportResult({this.geoJson, this.error});

  /// A GeoJSON FeatureCollection, ready for [GeoJsonParser].
  final Uint8List? geoJson;

  final String? error;
}

/// Converts KML/KMZ to GeoJSON so the farm import keeps a single validation
/// path — the app always stores and parses GeoJSON.
///
/// Only polygons are imported; Google Earth "Placemark" pins and "Path" lines
/// have no area and are skipped.
class KmlParser {
  /// KML is whitespace-separated lon,lat[,alt] tuples inside <coordinates>.
  static KmlImportResult toGeoJson(
    Uint8List bytes, {
    required String fileName,
  }) {
    try {
      final lower = fileName.toLowerCase();
      final String kmlText;
      if (lower.endsWith('.kmz')) {
        final extracted = _kmlFromKmz(bytes);
        if (extracted == null) {
          return const KmlImportResult(
            error: 'This KMZ does not contain a KML document.',
          );
        }
        kmlText = extracted;
      } else {
        kmlText = utf8.decode(bytes, allowMalformed: true);
      }
      return _parseKml(kmlText);
    } catch (e) {
      return KmlImportResult(error: 'Could not read KML: $e');
    }
  }

  static String? _kmlFromKmz(Uint8List bytes) {
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    ArchiveFile? found;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name.toLowerCase();
      if (!name.endsWith('.kml')) continue;
      // Google Earth writes doc.kml at the root; prefer it.
      found = f;
      if (name == 'doc.kml' || name.endsWith('/doc.kml')) break;
    }
    if (found == null) return null;

    final content = found.content;
    final Uint8List raw = content is Uint8List
        ? content
        : Uint8List.fromList(content as List<int>);
    return utf8.decode(raw, allowMalformed: true);
  }

  static KmlImportResult _parseKml(String kmlText) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(kmlText);
    } on XmlException catch (e) {
      return KmlImportResult(error: 'Not valid XML: ${e.message}');
    }

    final features = <Map<String, dynamic>>[];

    // 'namespace: *' matches both namespaced (standard) and bare KML, and works
    // through any Folder nesting.
    for (final placemark in doc.findAllElements('Placemark', namespace: '*')) {
      final rawName =
          placemark.getElement('name', namespace: '*')?.innerText.trim() ?? '';
      final name = rawName.isEmpty ? 'Paddock' : rawName;

      for (final polygon
          in placemark.findAllElements('Polygon', namespace: '*')) {
        final outerRing = _ring(polygon.getElement(
          'outerBoundaryIs',
          namespace: '*',
        ));
        if (outerRing == null || outerRing.length < 3) continue;

        final rings = <List<List<double>>>[outerRing];
        for (final inner
            in polygon.findElements('innerBoundaryIs', namespace: '*')) {
          final hole = _ring(inner);
          if (hole != null && hole.length >= 3) rings.add(hole);
        }

        features.add({
          'type': 'Feature',
          'properties': {'name': name},
          'geometry': {'type': 'Polygon', 'coordinates': rings},
        });
      }
    }

    if (features.isEmpty) {
      return const KmlImportResult(
        error: 'No paddock polygons found. Draw closed polygons in Google '
            'Earth — placemarks and paths are ignored.',
      );
    }

    final collection = {
      'type': 'FeatureCollection',
      'features': features,
    };
    return KmlImportResult(
      geoJson: Uint8List.fromList(utf8.encode(jsonEncode(collection))),
    );
  }

  /// Reads the <LinearRing><coordinates> ring from a boundary element.
  static List<List<double>>? _ring(XmlElement? boundary) {
    if (boundary == null) return null;
    final ring = boundary.getElement('LinearRing', namespace: '*');
    final raw =
        ring?.getElement('coordinates', namespace: '*')?.innerText.trim() ?? '';
    if (raw.isEmpty) return null;

    final points = <List<double>>[];
    for (final token in raw.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final parts = token.split(',');
      if (parts.length < 2) continue;
      final lon = double.tryParse(parts[0]);
      final lat = double.tryParse(parts[1]);
      if (lon == null || lat == null) continue;
      if (lat.abs() > 90 || lon.abs() > 180) continue;
      // Closed rings repeat the first point; the GeoJSON parser drops it.
      points.add([lon, lat]);
    }
    return points;
  }
}
