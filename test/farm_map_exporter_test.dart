import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/models/paddock.dart';
import 'package:tractorgps/services/farm_map_exporter.dart';
import 'package:tractorgps/services/geojson_parser.dart';
import 'package:tractorgps/services/kml_parser.dart';

/// Export must round-trip: what we write has to come back through the existing
/// importers with the same paddocks, or an export/import cycle loses the farm.
Paddock _square(String name, double lat, double lon, {List<LatLng>? hole}) {
  return Paddock(
    name: name,
    outer: [
      LatLng(lat, lon),
      LatLng(lat, lon + 0.002),
      LatLng(lat - 0.002, lon + 0.002),
      LatLng(lat - 0.002, lon),
    ],
    holes: hole == null ? const [] : [hole],
    areaHa: 3.9,
    labelPoint: LatLng(lat - 0.001, lon + 0.001),
  );
}

void main() {
  final paddocks = [
    _square('North 01', -37.67, 175.68),
    _square(
      'South, "block"',
      -37.676,
      175.68,
      hole: const [
        LatLng(-37.677, 175.681),
        LatLng(-37.677, 175.6815),
        LatLng(-37.6775, 175.6815),
      ],
    ),
  ];

  group('GeoJSON', () {
    test('writes a FeatureCollection with names and closed rings', () {
      final text = FarmMapExporter.toGeoJson(paddocks);
      final json = jsonDecode(text) as Map<String, dynamic>;

      expect(json['type'], 'FeatureCollection');
      final features = json['features'] as List;
      expect(features.length, 2);

      final ring =
          ((features.first as Map)['geometry']['coordinates'] as List).first
              as List;
      expect(ring.first, ring.last, reason: 'GeoJSON rings must be closed');
      expect((features.first as Map)['properties']['name'], 'North 01');
    });

    test('re-imports through GeoJsonParser', () {
      final bytes = FarmMapExporter.encode(paddocks, ExportFormat.geoJson);
      final parsed = GeoJsonParser.parseBytes(bytes);

      expect(parsed.error, isNull);
      expect(parsed.paddocks.length, 2);
      expect(
        parsed.paddocks.map((p) => p.name),
        containsAll(['North 01', 'South, "block"']),
      );
      // Holes survive the trip.
      expect(parsed.paddocks.last.holes.length, 1);
    });
  });

  group('KML', () {
    test('writes placemarks with an inner boundary for holes', () {
      final kml = FarmMapExporter.toKml(paddocks);

      expect(kml, contains('<Placemark>'));
      expect(kml, contains('<name>North 01</name>'));
      expect(kml, contains('<innerBoundaryIs>'));
      // XML-special characters in names must be escaped.
      expect(kml, contains('South, &quot;block&quot;'));
      expect(kml, isNot(contains('<name>South, "block"</name>')));
    });

    test('re-imports through KmlParser', () {
      final bytes = FarmMapExporter.encode(paddocks, ExportFormat.kml);
      final converted = KmlParser.toGeoJson(bytes, fileName: 'farm.kml');

      expect(converted.error, isNull);
      final parsed = GeoJsonParser.parseBytes(converted.geoJson!);
      expect(parsed.paddocks.length, 2);
      expect(
        parsed.paddocks.map((p) => p.name),
        containsAll(['North 01', 'South, "block"']),
      );
    });
  });

  group('CSV', () {
    test('has a header and one row per paddock, quoting commas', () {
      final csv = FarmMapExporter.toCsv(paddocks);
      final lines = const LineSplitter().convert(csv);

      expect(lines.first, startsWith('name,area_ha,vertices'));
      expect(lines.length, 3);
      // The name containing a comma must be quoted so the column count holds.
      expect(lines[2], startsWith('"South, ""block"""'));
      expect(lines[2].split(',').length, greaterThan(7));
    });

    test('encodes all three formats without throwing', () {
      for (final f in FarmMapExporter.formats) {
        expect(FarmMapExporter.encode(paddocks, f), isNotEmpty);
      }
    });
  });
}
