import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import '../lib/services/geometry.dart';

void main() {
  group('Grid-based accurate area calculations', () {
    test('Straight line basic case', () {
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.009, 175.0), // ~1000m south
      ];
      
      const swathWidthM = 20.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final gridArea = areaAppliedHaGridAccurate(path, swathWidthM);
      
      print('Simple area: $simpleArea ha');
      print('Grid-based area: $gridArea ha');
      print('Difference: ${(gridArea - simpleArea).abs()} ha');
      
      // Should be reasonably close
      expect((simpleArea - gridArea).abs(), lessThan(0.2));
    });
    
    test('Overlapping parallel lines', () {
      // Two parallel lines 1.5m apart with 20m swath = significant overlap
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.005, 175.0), // 500m south
        LatLng(-37.005, 175.00015), // 1.5m east
        LatLng(-37.0, 175.00015), // 500m north
      ];
      
      const swathWidthM = 20.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final gridArea = areaAppliedHaGridAccurate(path, swathWidthM);
      
      print('Overlapping parallel lines (1.5m apart, 20m swath):');
      print('  Simple (path × width): $simpleArea ha');
      print('  Grid-based (true area): $gridArea ha');
      print('  Simple overestimates by: ${simpleArea - gridArea} ha');
      print('  That\'s ${((simpleArea - gridArea) / simpleArea * 100).toStringAsFixed(1)}% overestimation');
      
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
          LatLng(-37.0, 175.0),
          LatLng(-37.005, 175.0),
          LatLng(-37.005, 175.00015),
          LatLng(-37.0, 175.00015),
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
      
      print('Job coverage calculations:');
      print('  Simple method: ${simpleCoverage.toStringAsFixed(1)}%');
      print('  Accurate method: ${accurateCoverage.toStringAsFixed(1)}%');
      
      // For overlapping paths, accurate should be lower
      expect(accurateCoverage, lessThanOrEqualTo(simpleCoverage));
    });
  });
}