import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import '../lib/services/geometry.dart';

void main() {
  group('Basic accurate area calculations', () {
    test('Straight line simple case', () {
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.009, 175.0), // ~1000m south
      ];
      
      const swathWidthM = 20.0;
      
      final simpleArea = areaAppliedHa(path, swathWidthM);
      final accurateArea = areaAppliedHaAccurate(path, swathWidthM);
      
      print('Simple area: $simpleArea ha');
      print('Accurate area: $accurateArea ha');
      
      // For straight line, should be similar
      expect((simpleArea - accurateArea).abs(), lessThan(0.1));
    });
    
    test('Basic coverage calculation', () {
      final path = [
        LatLng(-37.0, 175.0),
        LatLng(-37.009, 175.0),
      ];
      
      const swathWidthM = 20.0;
      const paddockAreaHa = 5.0;
      
      final simpleCoverage = coveragePercent(path, swathWidthM, paddockAreaHa);
      final accurateCoverage = coveragePercentAccurate(path, swathWidthM, paddockAreaHa);
      
      print('Simple coverage: $simpleCoverage%');
      print('Accurate coverage: $accurateCoverage%');
    });
  });
}