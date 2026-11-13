import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/models/job.dart';
import 'package:tractorgps/services/geometry.dart';

void main() {
  group('Grid-based accurate area calculations', () {
    test('Straight line basic case', () {
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.009, 175.0), // ~1000m south
      ];

      const swathWidthM = 20.0;

      final simpleArea = areaAppliedHa(path, swathWidthM);
      final gridArea = areaAppliedHaGridAccurate(path, swathWidthM);

      // Should be reasonably close
      expect((simpleArea - gridArea).abs(), lessThan(0.2));
    });

    test('Overlapping parallel lines', () {
      // Two parallel lines 1.5m apart with 20m swath = significant overlap
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.005, 175.0), // 500m south
        const LatLng(-37.005, 175.00015), // 1.5m east
        const LatLng(-37.0, 175.00015), // 500m north
      ];

      const swathWidthM = 20.0;

      final simpleArea = areaAppliedHa(path, swathWidthM);
      final gridArea = areaAppliedHaGridAccurate(path, swathWidthM);

      // Grid area should be less due to overlap
      expect(gridArea, lessThan(simpleArea));
    });

    test('Job model integration test', () {
      // Create a job with overlapping path
      final job = SavedJob(
        id: 'test-job',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        path: [
          const LatLng(-37.0, 175.0),
          const LatLng(-37.005, 175.0),
          const LatLng(-37.005, 175.00015),
          const LatLng(-37.0, 175.00015),
        ],
        paddockNames: ['Test Paddock'],
        totalHa: 5.0,
        avgSpeedKph: 8.0,
        swathWidthM: 20.0,
        hasSavedSwathWidth: true,
      );

      const fallbackWidth = 20.0;

      final simpleCoverage = job.coveragePercentFor(fallbackWidth);
      final accurateCoverage = job.coveragePercentAccurateFor(fallbackWidth);

      // For overlapping paths, accurate should be lower
      expect(accurateCoverage, lessThanOrEqualTo(simpleCoverage));
    });
  });
}
