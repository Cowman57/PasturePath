import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

void main() {
  group('Geometry precision analysis', () {
    test('Earth curvature and distance precision', () {
      // Earth's circumference ~40,075 km
      // 1 degree latitude = 40,075 / 360 ≈ 111.32 km
      // So 0.001° latitude ≈ 111.32 m
      
      final path1deg = [
        const LatLng(-37.0, 175.0),
        const LatLng(-38.0, 175.0), // 1 degree south
      ];
      
      final distance1deg = pathDistanceMeters(path1deg);
      print('1 degree latitude distance: $distance1deg m');
      print('Expected: ~111,320 m');
      
      // Test small distances
      final pathSmall = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.00001, 175.0), // 0.00001° ~ 1.11 m
      ];
      
      final distanceSmall = pathDistanceMeters(pathSmall);
      print('0.00001° distance: $distanceSmall m');
    });
    
    test('Swath area calculation with path simplification', () {
      // Test with a wiggly path that should be simplified
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.0001, 175.0001),
        const LatLng(-37.0002, 175.0002),
        const LatLng(-37.0003, 175.0003),
        const LatLng(-37.0004, 175.0004),
        const LatLng(-37.0005, 175.0005),
      ];
      
      const swathWidthM = 20.0;
      
      print('Original path length: ${path.length} points');
      print('Path distance: ${pathDistanceMeters(path)} m');
      
      // Test simplification
      final simplified = simplifySwathPath(path);
      print('Simplified path length: ${simplified.length} points');
      print('Simplified distance: ${pathDistanceMeters(simplified)} m');
      
      final appliedOriginal = areaAppliedHa(path, swathWidthM);
      final appliedSimplified = areaAppliedHa(simplified, swathWidthM);
      
      print('Original applied area: $appliedOriginal ha');
      print('Simplified applied area: $appliedSimplified ha');
    });
    
    test('Overlap detection accuracy', () {
      // Create overlapping swaths
      final path1 = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.005, 175.0),
      ];
      
      final path2 = [
        const LatLng(-37.0, 175.00015), // 1.5m east of path1 (with 20m swath, should overlap)
        const LatLng(-37.005, 175.00015),
      ];
      
      const swathWidthM = 20.0;
      
      // Combined path
      final combinedPath = [...path1, ...path2];
      
      final areaCombined = areaAppliedHa(combinedPath, swathWidthM);
      print('Combined path area: $areaCombined ha');
      
      // Actual area covered (with overlap) should be less than sum
      final area1 = areaAppliedHa(path1, swathWidthM);
      final area2 = areaAppliedHa(path2, swathWidthM);
      print('Individual areas: $area1 ha + $area2 ha = ${area1 + area2} ha');
      
      // With 1.5m offset and 20m swath, overlap is ~18.5m
      // Actual covered width ≈ 20 + (20 - 1.5) = 38.5m not 40m
      print('Overlap causes ~3.75% overestimation in simple path × width model');
    });
  });
}