import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tractorgps/services/geojson_parser.dart';
import 'package:tractorgps/services/kml_parser.dart';

/// KML is lon,lat — the opposite order to the LatLng constructor, which is the
/// classic way an import silently puts the farm in the wrong hemisphere.
const _kml = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark>
      <name>North Block</name>
      <Polygon>
        <outerBoundaryIs><LinearRing><coordinates>
          175.6800,-37.6700,0 175.6820,-37.6700,0 175.6820,-37.6720,0
          175.6800,-37.6720,0 175.6800,-37.6700,0
        </coordinates></LinearRing></outerBoundaryIs>
      </Polygon>
    </Placemark>
    <Placemark>
      <name>South Block</name>
      <Polygon>
        <outerBoundaryIs><LinearRing><coordinates>
          175.6800,-37.6740,0 175.6820,-37.6740,0 175.6820,-37.6760,0
          175.6800,-37.6760,0 175.6800,-37.6740,0
        </coordinates></LinearRing></outerBoundaryIs>
        <innerBoundaryIs><LinearRing><coordinates>
          175.6805,-37.6750,0 175.6810,-37.6750,0 175.6810,-37.6755,0
          175.6805,-37.6755,0 175.6805,-37.6750,0
        </coordinates></LinearRing></innerBoundaryIs>
      </Polygon>
    </Placemark>
  </Document>
</kml>
''';

void main() {
  test('KML polygons convert to paddocks with names and holes', () {
    final result = KmlParser.toGeoJson(
      Uint8List.fromList(utf8.encode(_kml)),
      fileName: 'farm.kml',
    );
    expect(result.error, isNull);
    expect(result.geoJson, isNotNull);

    final parsed = GeoJsonParser.parseBytes(result.geoJson!);
    expect(parsed.error, isNull);
    expect(parsed.paddocks.length, 2);

    final north = parsed.paddocks.firstWhere((p) => p.name == 'North Block');
    final south = parsed.paddocks.firstWhere((p) => p.name == 'South Block');

    expect(north.holes, isEmpty);
    expect(south.holes.length, 1);

    // ~222 m x ~176 m at this latitude ≈ 3.9 ha.
    expect(north.areaHa, closeTo(3.9, 0.5));
    // The hole must reduce the south block.
    expect(south.areaHa, lessThan(north.areaHa));

    // Coordinates must land in the southern hemisphere, not swapped.
    expect(north.outer.first.latitude, closeTo(-37.67, 0.001));
    expect(north.outer.first.longitude, closeTo(175.68, 0.001));
  });

  test('KMZ is unzipped and converted', () {
    final kmlBytes = utf8.encode(_kml);
    final archive = Archive()
      ..addFile(ArchiveFile('doc.kml', kmlBytes.length, kmlBytes));
    final zipped = ZipEncoder().encode(archive);
    expect(zipped, isNotNull);

    final result = KmlParser.toGeoJson(
      Uint8List.fromList(zipped!),
      fileName: 'farm.kmz',
    );
    expect(result.error, isNull);

    final parsed = GeoJsonParser.parseBytes(result.geoJson!);
    expect(parsed.paddocks.length, 2);
  });

  test('a KML with no polygons reports a helpful error', () {
    const pinsOnly = '''<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark><name>Gate</name><Point><coordinates>175.68,-37.67,0</coordinates></Point></Placemark>
  </Document>
</kml>
''';

    final result = KmlParser.toGeoJson(
      Uint8List.fromList(utf8.encode(pinsOnly)),
      fileName: 'pins.kml',
    );

    expect(result.geoJson, isNull);
    expect(result.error, contains('No paddock polygons'));
  });

  test('malformed XML is reported rather than thrown', () {
    final result = KmlParser.toGeoJson(
      Uint8List.fromList(utf8.encode('<kml><Document>')),
      fileName: 'broken.kml',
    );

    expect(result.geoJson, isNull);
    expect(result.error, isNotNull);
  });
}
