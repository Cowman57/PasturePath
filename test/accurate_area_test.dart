import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import '../lib/services/geometry.dart';
import '../lib/models/job.dart';

void main() {
  group('Accurate vs simple area calculations', () {
    test('Straight line comparison', () {
      // Simple straight line - both methods should give similar results
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.009, 175.0), // ~1000m south
      ];
      
      const swathWidthM = 20.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaAccurate(path, swathWidthM);
      
      print('Simple area: $simpleArea ha');
      print('Accurate area: $accurateArea ha');
      
      // Should be close
      expect((simpleArea - accurateArea).abs(), lessThan(0.05)); // Within 0.05 ha
    });
    
    test('Overlapping paths comparison', () {
      // Create overlapping parallel lines
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.005, 175.0), // 500m south
        LatLng(-37.005, 175.00015), // 1.5m east
        LatLng(-37.0, 175.00015), // 500m north (parallel to first line)
      ];
      
      const swathWidthM = 20.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaAccurate(path, swathWidthM);
      
      print('Overlapping paths:');
      print('  Simple area: $simpleArea ha');
      print('  Accurate area: $accurateArea ha');
      print('  Difference: ${simpleArea - accurateArea} ha (${((simpleArea - accurateArea) / simpleArea * 100).toStringAsFixed(1)}%)');
      
      // Accurate area should be less due to overlap
      expect(accurateArea, lessThan(simpleArea));
    });
    
    test('Wiggly path comparison', () {
      // Create a wiggly path
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.0005, 175.0001),
        LatLng(-37.0010, 175.0000),
        LatLng(-37.0015, 175.0002),
        LatLng(-37.0020, 175.0001),
        LatLng(-37.0025, 175.0003),
      ];
      
      const swathWidthM = 15.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaAccurate(path, swathWidthM);
      
      print('Wiggly path:');
      print('  Simple area: $simpleArea ha');
      print('  Accurate area: $accurateArea ha');
    });
    
    test('Job model integration', () {
      final job = SavedJob(
        id: 'test',
        startedAt: DateTime.now(),
        endedAt: DateTime.now(),
        path: [
          LatLng(-37.0, 175.0),
          LatLng(-37.005, 175.0),
          LatLng(-37.005, 175.00015),
          LatLng(-37.0, 175.00015),
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
      
      print('Job calculations:');
      print('  Simple area: $simpleArea ha');
      print('  Accurate area: $accurateArea ha');
      print('  Simple coverage: $simpleCoverage%');
      print('  Accurate coverage: $accurateCoverage%');
      
      // For overlapping paths, accurate coverage should be lower
      expect(accurateCoverage, lessThanOrEqualTo(simpleCoverage));
    });
  });
}