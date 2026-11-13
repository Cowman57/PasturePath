import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

void main() {
  group('Simplified accurate area calculations', () {
    test('Straight line basic case', () {
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.009, 175.0), // ~1000m south
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
        const LatLng(-37.0, 175.0),
        const LatLng(-37.005, 175.0), // 500m south
        const LatLng(-37.005, 175.00015), // 1.5m east
        const LatLng(-37.0, 175.00015), // 500m north (back)
      ];
      
      const swathWidthM = 20.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaSimplifiedAccurate(path, swathWidthM);
      
      print('Overlapping parallel lines:');
      print('  Simple area: $simpleArea ha');
      print('  Accurate area: $accurateArea ha');
      print('  Difference: ${simpleArea - accurateArea} ha');
      
      // Per-segment rectangles do not subtract overlap, so this tracks the
      // simple estimate and only differs by local projection error.
      expect((accurateArea - simpleArea).abs(), lessThan(simpleArea * 0.01));

      // Real overlap-aware coverage comes from the grid method.
      final gridArea = areaAppliedHaGridAccurate(path, swathWidthM);
      expect(gridArea, lessThan(simpleArea));
    });
    
    test('Right angle turn', () {
      // L-shaped path
      final path = [
        const LatLng(-37.0, 175.0),
        const LatLng(-37.005, 175.0), // 500m south
        const LatLng(-37.005, 175.0003), // 3m east
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