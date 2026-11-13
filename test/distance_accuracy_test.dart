import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

/// Ground-truth accuracy checks for the distance/area chain.
///
/// Expected values are derived from the mean Earth radius (6371000 m), i.e.
/// 1 degree of latitude = pi/180 * 6371000 = 111194.93 m. This is deliberately
/// independent of latlong2 so the tests can catch rounding inside the library.
void main() {
  const metresPerDegreeLat = 111194.93; // pi/180 * 6371000

  /// Straight north-south path of [segments] steps, each [stepM] metres.
  List<LatLng> pathOfSegments({
    required int segments,
    required double stepM,
  }) {
    final dLat = stepM / metresPerDegreeLat;
    return [for (var i = 0; i <= segments; i++) LatLng(-37.0 - i * dLat, 175.0)];
  }

  group('pathDistanceMeters ground truth', () {
    test('many small segments do not lose length to per-segment rounding', () {
      // 199 steps of ~2.4 m — the spacing of real ~25 Hz GPS fixes.
      final path = pathOfSegments(segments: 199, stepM: 2.4096);
      const expectedM = 199 * 2.4096; // 479.51 m

      final actual = pathDistanceMeters(path);

      expect(
        actual,
        closeTo(expectedM, expectedM * 0.005),
        reason: 'path length must be within 0.5% of the true 479.5 m',
      );
    });

    test('1000 m single segment is accurate', () {
      final path = pathOfSegments(segments: 1, stepM: 1000.0);
      expect(pathDistanceMeters(path), closeTo(1000.0, 5.0));
    });

    test('degenerate paths return zero', () {
      expect(pathDistanceMeters(const []), 0);
      expect(pathDistanceMeters([const LatLng(-37.0, 175.0)]), 0);
    });
  });

  group('areaAppliedHa ground truth', () {
    test('140 m x 20 m swath equals 0.28 ha', () {
      // 100 steps of 1.4 m => 140 m of travel => 140 * 20 / 10000 = 0.28 ha
      final path = pathOfSegments(segments: 100, stepM: 1.4);
      const expectedHa = 140.0 * 20.0 / 10000.0;

      expect(areaAppliedHa(path, 20.0), closeTo(expectedHa, 0.002));
    });

    test('1000 m x 20 m swath equals 2.0 ha', () {
      final path = pathOfSegments(segments: 1, stepM: 1000.0);
      expect(areaAppliedHa(path, 20.0), closeTo(2.0, 0.02));
    });
  });

  group('sanitizeAppliedPathDistanceM', () {
    test('keeps a stored distance that matches geometry', () {
      final path = pathOfSegments(segments: 199, stepM: 2.4096);
      // Real recorded 479.5 m must not be discarded as "inflated".
      expect(sanitizeAppliedPathDistanceM(479.5, path), closeTo(479.5, 2.5));
    });

    test('still corrects a genuinely inflated stored distance', () {
      final path = pathOfSegments(segments: 199, stepM: 2.4096);
      expect(sanitizeAppliedPathDistanceM(1000.0, path), closeTo(479.5, 2.5));
    });
  });

  group('simplifySwathPath error budget', () {
    /// Arc starting north and turning right, sampled every [stepM] metres.
    List<LatLng> arc(double radiusM, double sweepDeg, double stepM) {
      final sweepRad = sweepDeg * math.pi / 180.0;
      final totalLen = radiusM * sweepRad;
      final n = (totalLen / stepM).round();
      final cosLat = math.cos(-37.0 * math.pi / 180.0);
      return [
        for (var i = 0; i <= n; i++)
          () {
            final s = totalLen * i / n;
            final th = s / radiusM;
            final east = radiusM * (1 - math.cos(th));
            final north = radiusM * math.sin(th);
            return LatLng(
              -37.0 + north / metresPerDegreeLat,
              175.0 + east / (metresPerDegreeLat * cosLat),
            );
          }(),
      ];
    }

    // Recorded points are at least _minGpsRecordM (0.45 m) apart, so this is the
    // finest sampling the app ever measures. Tight headland turns are the worst
    // case for chord-based simplification.
    test('1.25 m simplification loses under 1.5% on a tight 3 m turn', () {
      final path = arc(3.0, 180, 0.45);
      const trueLen = math.pi * 3.0; // half circle = 9.42 m
      final simplified = simplifySwathPath(path, minDistM: 1.25);

      final error = (pathDistanceMeters(simplified) - trueLen) / trueLen;
      expect(error, greaterThan(-0.015), reason: 'must not under-count >1.5%');
    });
  });

  group('areaAppliedHaGridAccurate ground truth', () {
    List<LatLng> straightLine(double lenM, {double stepM = 0.45}) {
      final n = (lenM / stepM).round();
      return [
        for (var i = 0; i <= n; i++)
          LatLng(-37.0 + (lenM * i / n) / metresPerDegreeLat, 175.0),
      ];
    }

    // A straight uniform swath has an exact answer: length x width. The old
    // whole-cell stamping was measured at +34.7% (3 m swath) here.
    test('500 m x 3 m straight run is within 1% of exact', () {
      final path = straightLine(500);
      const exactHa = 500.0 * 3.0 / 10000.0;
      expect(areaAppliedHaGridAccurate(path, 3.0), closeTo(exactHa, exactHa * 0.01));
    });

    test('2000 m x 12 m straight run is within 1% of exact', () {
      final path = straightLine(2000);
      const exactHa = 2000.0 * 12.0 / 10000.0;
      expect(
        areaAppliedHaGridAccurate(path, 12.0),
        closeTo(exactHa, exactHa * 0.01),
      );
    });

    test('overlapping double pass counts the union, not both passes', () {
      const len = 500.0;
      const widthM = 20.0;
      const gap = 1.5;
      final cosLat = math.cos(-37.0 * math.pi / 180.0);
      double latAt(double n) => -37.0 + n / metresPerDegreeLat;
      double lonAt(double e) => 175.0 + e / (metresPerDegreeLat * cosLat);
      final n = (len / 0.45).round();

      final path = <LatLng>[
        for (var i = 0; i <= n; i++) LatLng(latAt(len * i / n), lonAt(0)),
        LatLng(latAt(len), lonAt(gap)),
        for (var i = 0; i <= n; i++)
          LatLng(latAt(len - len * i / n), lonAt(gap)),
      ];

      final gridHa = areaAppliedHaGridAccurate(path, widthM);
      final simpleHa = areaAppliedHa(path, widthM);

      // Two 20 m passes 1.5 m apart overlap almost completely: the true union
      // is one ~21.5 m wide band, roughly half the naive path x width.
      expect(gridHa, lessThan(simpleHa * 0.65));
      const unionHa = len * (widthM + gap) / 10000.0;
      expect(gridHa, closeTo(unionHa, unionHa * 0.1));
    });
  });
}
