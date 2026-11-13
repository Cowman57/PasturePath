import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

void main() {
  group('Basic accurate area calculations', () {
    test('Straight line simple case', () {
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.009, 175.0), // ~1000m south
      ];

      const swathWidthM = 20.0;

      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaGridAccurate(path, swathWidthM);

      // For a straight line, both methods should agree closely.
      expect((simpleArea - accurateArea).abs(), lessThan(0.1));
    });

    test('Basic coverage calculation', () {
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.009, 175.0),
      ];

      const swathWidthM = 20.0;
      const paddockAreaHa = 5.0;

      final simpleCoverage = coveragePercent(
        path,
        swathWidthM,
        paddockAreaHa,
      );
      final accurateCoverage = coveragePercentGridAccurate(
        path,
        swathWidthM,
        paddockAreaHa,
      );

      expect(simpleCoverage, greaterThan(0));
      expect(accurateCoverage, greaterThan(0));
    });
  });
}
