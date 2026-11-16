import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

/// Reversing into a tight corner must be recorded on the track but must not
/// paint swath — the operator backs into position and only applies product on
/// the way out.
void main() {
  const metresPerDegreeLat = 111194.93; // pi/180 * 6371000
  const startLat = -37.0;
  const startLon = 175.0;

  LatLng atNorth(double metres) =>
      LatLng(startLat + metres / metresPerDegreeLat, startLon);

  /// Builds a north-south path through each [legEnd] in turn, at [stepM] spacing.
  /// Positive legs head north, negative south.
  List<LatLng> pathThroughLegs(
    List<double> legEnd, {
    double stepM = 1.0,
  }) {
    final points = <LatLng>[];
    var position = 0.0;
    points.add(atNorth(position));

    for (final target in legEnd) {
      final direction = target > position ? 1.0 : -1.0;
      while ((target - position).abs() > 1e-9) {
        position += direction * math.min(stepM, (target - position).abs());
        points.add(atNorth(position));
      }
    }
    return points;
  }

  double totalLengthM(List<LatLng> path) => pathDistanceMeters(path);

  group('reversal detection', () {
    test('a real reversal splits into forward / reversing / forward', () {
      // 20 m out, 10 m back, then out again to 30 m.
      final path = pathThroughLegs([20, 10, 30]);
      final runs = splitPathByTravelDirection(path);

      expect(runs.length, 3, reason: 'expected three travel runs');
      expect(runs[0].reversing, isFalse);
      expect(runs[1].reversing, isTrue);
      expect(runs[2].reversing, isFalse);
    });

    test('the reversing leg is excluded from the swath runs', () {
      final path = pathThroughLegs([20, 10, 30]);
      final forward = forwardRunsOnly(path);

      expect(forward.length, 2);

      // 20 m out + 20 m out again = 40 m. The 10 m reverse is not painted.
      final forwardM = forward.fold<double>(0, (sum, run) {
        return sum + totalLengthM(run);
      });
      expect(forwardM, closeTo(40, 1.5));

      final wholePathM = totalLengthM(path);
      expect(wholePathM, closeTo(50, 1.5));
      expect(forwardM, lessThan(wholePathM));
    });

    test('a sub-metre jitter flick does not start a reversal', () {
      // Mostly forward, with one 0.3 m back-flick of the kind GPS produces.
      final path = <LatLng>[
        for (var i = 0; i <= 10; i++) atNorth(i.toDouble()),
        atNorth(9.7),
        for (var i = 10; i <= 20; i++) atNorth(i.toDouble()),
      ];

      final runs = splitPathByTravelDirection(path);
      expect(runs.length, 1);
      expect(runs.single.reversing, isFalse);
    });

    test('a reversal produces its own swath ribbons, not one chord', () {
      final path = pathThroughLegs([20, 10, 30]);
      final rings = buildSwathRingsFromPath(path, 3.0);

      // Two forward legs → two ribbons. A single ring would mean the reversed
      // section was painted as one straight strip across the corner.
      expect(rings.length, 2);

      // Each ribbon is a valid polygon outline (flutter_map closes the ring on
      // render, so the points themselves need not repeat the first vertex).
      for (final ring in rings) {
        expect(ring.length, greaterThanOrEqualTo(4));
      }
    });

    test('a straight run is still a single ribbon', () {
      final path = pathThroughLegs([30]);
      final rings = buildSwathRingsFromPath(path, 3.0);

      expect(rings.length, 1);
    });
  });
}
