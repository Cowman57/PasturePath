import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../models/paddock.dart';

/// A farm-map export format offered to the user.
enum ExportFormat {
  geoJson('GeoJSON', 'geojson', 'application/geo+json'),
  kml('KML (Google Earth)', 'kml', 'application/vnd.google-earth.kml+xml'),
  csv('CSV (spreadsheet)', 'csv', 'text/csv');

  const ExportFormat(this.label, this.extension, this.mimeType);

  final String label;
  final String extension;
  final String mimeType;
}

/// Serialises the farm map (paddock boundaries) to the formats PasturePath can
/// export. Import lives in [GeoJsonParser] / [KmlParser]; this is the inverse.
///
/// Everything here is pure: no file IO, no Flutter widgets, so it can be unit
/// tested directly.
class FarmMapExporter {
  const FarmMapExporter._();

  /// Formats shown in the export dialog, in display order.
  static const List<ExportFormat> formats = <ExportFormat>[
    ExportFormat.geoJson,
    ExportFormat.kml,
    ExportFormat.csv,
  ];

  /// Encodes [paddocks] in [format] as UTF-8 bytes ready to write to disk.
  static Uint8List encode(List<Paddock> paddocks, ExportFormat format) {
    final text = switch (format) {
      ExportFormat.geoJson => toGeoJson(paddocks),
      ExportFormat.kml => toKml(paddocks),
      ExportFormat.csv => toCsv(paddocks),
    };
    return Uint8List.fromList(utf8.encode(text));
  }

  // ---------- GeoJSON ----------

  /// A GeoJSON `FeatureCollection`, one `Polygon` feature per paddock with the
  /// name and area carried in `properties`. Re-importable by [GeoJsonParser].
  static String toGeoJson(List<Paddock> paddocks) {
    final features = <Map<String, dynamic>>[];
    for (final p in paddocks) {
      final rings = <List<List<double>>>[
        _ring(p.outer),
        for (final hole in p.holes) _ring(hole),
      ];
      features.add({
        'type': 'Feature',
        'properties': {
          'name': p.name,
          'area_ha': double.parse(p.areaHa.toStringAsFixed(4)),
        },
        'geometry': {'type': 'Polygon', 'coordinates': rings},
      });
    }
    return const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'features': features,
    });
  }

  /// Closes the ring and writes `[lon, lat]` pairs, as GeoJSON requires.
  static List<List<double>> _ring(List<LatLng> points) {
    final out = <List<double>>[
      for (final pt in points) [pt.longitude, pt.latitude],
    ];
    if (out.isNotEmpty) {
      final first = out.first;
      final last = out.last;
      if (first[0] != last[0] || first[1] != last[1]) {
        out.add([first[0], first[1]]);
      }
    }
    return out;
  }

  // ---------- KML ----------

  /// KML 2.2 document. Opens directly in Google Earth and re-imports here.
  static String toKml(List<Paddock> paddocks) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2">')
      ..writeln('  <Document>')
      ..writeln('    <name>PasturePath farm map</name>');
    for (final p in paddocks) {
      b
        ..writeln('    <Placemark>')
        ..writeln('      <name>${_escapeXml(p.name)}</name>')
        ..writeln('      <ExtendedData>')
        ..writeln('        <Data name="area_ha">')
        ..writeln('          <value>${p.areaHa.toStringAsFixed(4)}</value>')
        ..writeln('        </Data>')
        ..writeln('      </ExtendedData>')
        ..writeln('      <Polygon>')
        ..writeln('        <outerBoundaryIs>')
        ..writeln('          <LinearRing>')
        ..writeln('            <coordinates>${_kmlCoords(p.outer)}</coordinates>')
        ..writeln('          </LinearRing>')
        ..writeln('        </outerBoundaryIs>');
      for (final hole in p.holes) {
        b
          ..writeln('        <innerBoundaryIs>')
          ..writeln('          <LinearRing>')
          ..writeln('            <coordinates>${_kmlCoords(hole)}</coordinates>')
          ..writeln('          </LinearRing>')
          ..writeln('        </innerBoundaryIs>');
      }
      b
        ..writeln('      </Polygon>')
        ..writeln('    </Placemark>');
    }
    b
      ..writeln('  </Document>')
      ..writeln('</kml>');
    return b.toString();
  }

  /// KML wants `lon,lat,alt` triples, closed, in one whitespace-separated blob.
  static String _kmlCoords(List<LatLng> points) {
    final parts = <String>[
      for (final pt in points)
        '${pt.longitude.toStringAsFixed(8)},${pt.latitude.toStringAsFixed(8)},0',
    ];
    if (points.isNotEmpty) {
      final first = points.first;
      parts.add(
        '${first.longitude.toStringAsFixed(8)},'
        '${first.latitude.toStringAsFixed(8)},0',
      );
    }
    return parts.join(' ');
  }

  static String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  // ---------- CSV ----------

  /// One row per paddock: name, area, vertex count, centroid, and the raw
  /// boundary as a `lat lon` pair list. Handy for spreadsheets and for feeding
  /// other farm software that reads polygons as text.
  static String toCsv(List<Paddock> paddocks) {
    final b = StringBuffer()
      ..writeln('name,area_ha,vertices,centroid_lat,centroid_lon,hole_count,outer_ring');
    for (final p in paddocks) {
      final centroid = _centroid(p.outer);
      b.writeln([
        _csvCell(p.name),
        p.areaHa.toStringAsFixed(4),
        p.outer.length.toString(),
        centroid.latitude.toStringAsFixed(8),
        centroid.longitude.toStringAsFixed(8),
        p.holes.length.toString(),
        _csvCell(
          p.outer
              .map((pt) => '${pt.latitude.toStringAsFixed(8)} '
                  '${pt.longitude.toStringAsFixed(8)}')
              .join('; '),
        ),
      ].join(','));
    }
    return b.toString();
  }

  /// Mean of the ring vertices — good enough for a label point, and stable for
  /// convex-ish paddocks. Not an area-weighted centroid.
  static LatLng _centroid(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(0, 0);
    var lat = 0.0;
    var lon = 0.0;
    for (final pt in points) {
      lat += pt.latitude;
      lon += pt.longitude;
    }
    return LatLng(lat / points.length, lon / points.length);
  }

  static String _csvCell(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
