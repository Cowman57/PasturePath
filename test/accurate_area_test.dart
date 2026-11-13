import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/models/job.dart';
import 'package:tractorgps/services/geometry.dart';

void main() {
  group('Accurate vs simple area calculations', () {
    test('Straight line comparison', () {
      // Simple straight line - both methods should give similar results
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.009, 175.0), // ~1000m south
      ];

      const swathWidthM = 20.0;

      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaGridAccurate(path, swathWidthM);

      // Should be close
      expect((simpleArea - accurateArea).abs(), lessThan(0.05)); // Within 0.05 ha
    });

    test('Overlapping paths comparison', () {
      // Create overlapping parallel lines
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.005, 175.0), // 500m south
        const LatLng(-37.005, 175.00015), // 1.5m east
        const LatLng(-37.0, 175.00015), // 500m north (parallel to first line)
      ];

      const swathWidthM = 20.0;

      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaGridAccurate(path, swathWidthM);

      // Accurate area should be less due to overlap
      expect(accurateArea, lessThan(simpleArea));
    });

    test('Wiggly path comparison', () {
      // Create a wiggly path
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.0005, 175.0001),
        const LatLng(-37.0010, 175.0000),
        const LatLng(-37.0015, 175.0002),
        const LatLng(-37.0020, 175.0001),
        const LatLng(-37.0025, 175.0003),
      ];

      const swathWidthM = 15.0;

      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaGridAccurate(path, swathWidthM);

      expect(simpleArea, greaterThan(0));
      expect(accurateArea, greaterThan(0));
    });

    test('Job model integration', () {
      final job = SavedJob(
        id: 'test',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        path: [
          const LatLng(-37.0, 175.0),
          const LatLng(-37.005, 175.0),
          const LatLng(-37.005, 175.00015),
          const LatLng(-37.0, 175.00015),
        ],
        paddockNames: ['Test'],
        totalHa: 5.0,
        avgSpeedKph: 8.0,
        swathWidthM: 20.0,
        hasSavedSwathWidth: true,
      );

      const fallbackWidth = 20.0;

      final simpleArea = job.areaAppliedHaFor(fallbackWidth);
      final accurateArea = job.areaAppliedHaAccurateFor(fallbackWidth);
      final simpleCoverage = job.coveragePercentFor(fallbackWidth);
      final accurateCoverage = job.coveragePercentAccurateFor(fallbackWidth);

      expect(simpleArea, greaterThan(0));
      expect(accurateArea, greaterThan(0));

      // For overlapping paths, accurate coverage should be lower
      expect(accurateCoverage, lessThanOrEqualTo(simpleCoverage));
    });
  });
}
