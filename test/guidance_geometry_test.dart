import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

void main() {
  test('guidanceParallelSpanM applies 2x safety and cap', () {
    expect(
      guidanceParallelSpanM(perpendicularExtentM: 100, safetyFactor: 2, capM: 500),
      200,
    );
    expect(
      guidanceParallelSpanM(perpendicularExtentM: 300, safetyFactor: 2, capM: 500),
      500,
    );
  });

  test('perpendicular extent for rectangle across AB', () {
    const origin = LatLng(-37.0, 175.0);
    // ~100 m east-west span at this latitude (roughly 0.001 deg lon)
    final ring = [
      LatLng(-37.0000, 175.0000),
      LatLng(-37.0000, 175.0010),
      LatLng(-37.0005, 175.0010),
      LatLng(-37.0005, 175.0000),
    ];
    // AB north-south: normal points east
    final extent = guidancePerpendicularExtentM(
      origin: origin,
      normalEast: 1,
      normalNorth: 0,
      outerRings: [ring],
    );
    expect(extent, greaterThan(50));
    expect(extent, lessThan(150));
  });
}
