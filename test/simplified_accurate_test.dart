import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import '../lib/services/geometry.dart';

void main() {
  group('Simplified accurate area calculations', () {
    test('Straight line basic case', () {
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.009, 175.0), // ~1000m south
      ];
      
      const swathWidthM = 20.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaSimplifiedAccurate(path, swathWidthM);
      
      print('Simple area: $simpleArea ha');
      print('Simplified accurate area: $accurateArea ha');
      
      // Should be close
      expect((simpleArea - accurateArea).abs(), lessThan(0.1));
    });
    
    test('Two parallel lines with overlap', () {
      // Two parallel lines 1.5m apart with 20m swath = 18.5m overlap
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.005, 175.0), // 500m south
        LatLng(-37.005, 175.00015), // 1.5m east
        LatLng(-37.0, 175.00015), // 500m north (back)
      ];
      
      const swathWidthM = 20.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaSimplifiedAccurate(path, swathWidthM);
      
      print('Overlapping parallel lines:');
      print('  Simple area: $simpleArea ha');
      print('  Accurate area: $accurateArea ha');
      print('  Difference: ${simpleArea - accurateArea} ha');
      
      // Accurate area should be less due to overlap
      expect(accurateArea, lessThan(simpleArea));
    });
    
    test('Right angle turn', () {
      // L-shaped path
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.005, 175.0), // 500m south
        LatLng(-37.005, 175.0003), // 3m east
      ];
      
      const swathWidthM = 15.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaSimplifiedAccurate(path, swathWidthM);
      
      print('L-shaped path:');
      print('  Simple area: $simpleArea ha');
      print('  Accurate area: $accurateArea ha');
    });
  });
}