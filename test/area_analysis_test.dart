import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

void main() {
  group('Area and coverage calculation issues', () {
    test('Simple rectangular area test', () {
      // Create a simple rectangular path: 1000m × 20m swath
      // Path: 1000m north-south line
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.009, 175.0), // ~1000m south
      ];
      
      const swathWidthM = 20.0;
      
      // Current calculation: path distance × swath width
      final pathDistance = pathDistanceMeters(path);
      print('Path distance: $pathDistance m');
      
      final appliedArea = areaAppliedHa(path, swathWidthM);
      print('Applied area: $appliedArea ha');
      
      // Expected: 1000m × 20m = 20,000 m² = 2.0 ha
      const expectedArea = 1000.0 * swathWidthM / 10000.0; // 2.0 ha
      print('Expected area: $expectedArea ha');
      
      // Let's see what latlong2 distance gives us
      final distance = const Distance().as(LengthUnit.Meter, path[0], path[1]);
      print('Direct latlong2 distance: $distance m');
    });
    
    test('Grid path with overlaps', () {
      // Create a grid pattern where we might get double counting
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.005, 175.0), // 500m south
        const LatLng(-37.005, 175.001), // east
        const LatLng(-37.0, 175.001), // north
        const LatLng(-37.0, 175.002), // east again
        const LatLng(-37.005, 175.002), // south again (overlapping previous swath)
      ];
      
      const swathWidthM = 20.0;
      
      final pathDistance = pathDistanceMeters(path);
      print('Grid path distance: $pathDistance m');
      
      final appliedArea = areaAppliedHa(path, swathWidthM);
      print('Grid applied area: $appliedArea ha');
      
      // With overlaps, the simple path length × width overestimates
      // Actual area covered might be less due to overlaps
      print('Potential issue: overlaps cause overestimation');
    });
    
    test('Paddock area vs applied area comparison', () {
      // Paddock area: 10 ha (100,000 m²)
      const paddockAreaHa = 10.0;
      
      // Path covers approximately 5 ha (50,000 m²)
      // Path length: 2500m × swath width 20m = 50,000 m² = 5 ha
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.0225, 175.0), // ~2500m south
      ];
      
      const swathWidthM = 20.0;
      
      final coverage = coveragePercent(path, swathWidthM, paddockAreaHa);
      print('Coverage percentage: $coverage%');
      print('Expected: 50%');
    });
  });
}