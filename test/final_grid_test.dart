import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
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
      
      print('=== Straight line test ===');
      print('Simple area: $simpleArea ha');
      print('Grid-based area: $gridArea ha');
      print('Difference: ${(gridArea - simpleArea).abs()} ha');
      
      // Should be reasonably close
      expect((simpleArea - gridArea).abs(), lessThan(0.2));
    });
    
    test('Overlapping parallel lines - true area vs simple estimate', () {
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
      
      print('\n=== Overlap test ===');
      print('Path: 2 parallel lines 500m long, 1.5m apart');
      print('Swath width: ${swathWidthM}m');
      print('Simple (path × width): $simpleArea ha');
      print('Grid-based (true area): $gridArea ha');
      print('Simple overestimates by: ${simpleArea - gridArea} ha');
      print('Overestimation: ${((simpleArea - gridArea) / simpleArea * 100).toStringAsFixed(1)}%');
      
      // Mathematical check:
      // Two 500m lines × 20m width = 20,000 m² = 2.0 ha total if no overlap
      // But with 1.5m offset, overlap = 20 - 1.5 = 18.5m overlap per line
      // Actual width covered = 20 + (20 - 1.5) = 38.5m, not 40m
      // So actual area = 500 × 38.5 = 19,250 m² = 1.925 ha
      // Simple method gives: 1000m total path × 20m = 20,000 m² = 2.0 ha
      // Expected overestimation: 0.075 ha (3.75%)
      
      print('Expected: ~1.925 ha (3.75% less than 2.0 ha)');
      
      // Grid area should be less due to overlap
      expect(gridArea, lessThan(simpleArea));
    });
    
    test('Coverage percentage calculation', () {
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.009, 175.0), // ~1000m south
      ];
      
      const swathWidthM = 20.0;
      const paddockAreaHa = 10.0;
      
      final simpleCoverage = coveragePercent(path, swathWidthM, paddockAreaHa);
      final gridCoverage = coveragePercentGridAccurate(path, swathWidthM, paddockAreaHa);
      
      print('\n=== Coverage test ===');
      print('Simple coverage: ${simpleCoverage.toStringAsFixed(1)}%');
      print('Grid-based coverage: ${gridCoverage.toStringAsFixed(1)}%');
    });
  });
}