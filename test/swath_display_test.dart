import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';
import 'dart:math' as math;

LatLng _offsetNorth(LatLng p, double metres) {
  return LatLng(p.latitude + metres / 111320.0, p.longitude);
}

List<SwathStamp> _lineStamps(LatLng start, int count, double stepM) {
  return [
    for (int i = 0; i < count; i++)
      SwathStamp(_offsetNorth(start, i * stepM), 0),
  ];
}

void main() {
  test('simplifySwathStamps reduces dense recording', () {
    const start = LatLng(-37.0, 175.0);
    final dense = _lineStamps(start, 200, 0.06);
    final simplified = simplifySwathStamps(dense, minDistM: 0.45);
    expect(simplified.length, lessThan(dense.length));
    expect(simplified.length, greaterThan(10));
    expect(simplified.first.center, dense.first.center);
    expect(simplified.last.center, dense.last.center);
  });

  test('pathDistanceMFromStamps sums segment lengths', () {
    const start = LatLng(-37.0, 175.0);
    final stamps = _lineStamps(start, 11, 1.0);
    expect(pathDistanceMFromStamps(stamps), closeTo(10.0, 0.5));
  });

  test('oriented swath ring uses bevel joins at corners', () {
    final stamps = [
      SwathStamp(const LatLng(-37.0, 175.0), 0),
      SwathStamp(const LatLng(-37.0005, 175.0), 0),
      SwathStamp(const LatLng(-37.0005, 175.0005), 90),
      SwathStamp(const LatLng(-37.001, 175.0005), 90),
    ];
    final ring = buildSwathRingFromOrientedStamps(stamps, 3.0);
    expect(ring.length, greaterThan(6));
  });

  test('filterForwardGpsPath drops GPS back-flicks', () {
    const a = LatLng(-37.0, 175.0);
    final b = LatLng(a.latitude + 0.00005, a.longitude);
    final c = LatLng(a.latitude + 0.00002, a.longitude); // back toward a
    final filtered = filterForwardGpsPath([a, b, c]);
    expect(filtered.length, 2);
    expect(filtered.last, b);
  });

  test('splitPathAtReversals breaks backtrack into separate segments', () {
    const a = LatLng(-37.0, 175.0);
    final b = LatLng(a.latitude + 0.0001, a.longitude);
    final c = LatLng(a.latitude + 0.00005, a.longitude); // back toward a
    final d = LatLng(a.latitude - 0.00005, a.longitude); // continue reversing
    final segs = splitPathAtReversals([a, b, c, d]);
    expect(segs.length, 2);
    expect(segs[0].length, 2);
    expect(segs[1].length, 2);
  });

  test('implementCenterPathFromGps offsets behind travel tangent', () {
    const a = LatLng(-37.0, 175.0);
    final b = LatLng(a.latitude + 0.0001, a.longitude);
    final boom = implementCenterPathFromGps(
      [a, b],
      gpsBehindM: 0,
      gpsLateralM: 0,
      hitchToAxleM: 3,
      boomLateralM: 0,
    );
    expect(boom.length, 2);
    final behindM = const Distance().as(LengthUnit.Meter, a, boom[0]);
    expect(behindM, closeTo(3, 1.0));
  });

  test('buildSwathRingFromOrientedStamps merges a chunk into one ring', () {
    const start = LatLng(-37.0, 175.0);
    final stamps = _lineStamps(start, 50, 1.0);
    final ring = buildSwathRingFromOrientedStamps(stamps, 3.0);
    expect(ring.length, greaterThan(6));
  });

  test('simplifySwathPath shortens zig-zag GPS more than straight travel', () {
    const start = LatLng(-37.0, 175.0);
    final gps = <LatLng>[];
    for (int i = 0; i < 60; i++) {
      final northM = i * 1.0;
      final eastM = (i.isEven ? 0.35 : -0.35);
      final lat = start.latitude + northM / 111320.0;
      final lon = start.longitude +
          eastM / (111320.0 * math.cos(start.latitude * math.pi / 180.0));
      gps.add(LatLng(lat, lon));
    }

    final simplified = simplifySwathPath(gps, minDistM: 1.25);
    final rawLen = pathDistanceMeters(gps);
    final simpleLen = pathDistanceMeters(simplified);
    expect(simpleLen, lessThan(rawLen * 0.95));
    expect(simpleLen, closeTo(59.0, 12.0));
  });

  test('simplifySwathPath at 1.25 m keeps an L-corner', () {
    const corner = LatLng(-37.0, 175.0);
    final path = <LatLng>[];
    // Approach north to corner
    for (int i = 20; i >= 0; i--) {
      path.add(_offsetNorth(corner, -i * 0.4));
    }
    // Leave east from corner
    for (int i = 1; i <= 20; i++) {
      final eastM = i * 0.4;
      final lon = corner.longitude +
          eastM / (111320.0 * math.cos(corner.latitude * math.pi / 180.0));
      path.add(LatLng(corner.latitude, lon));
    }

    final simplified = simplifySwathPath(path, minDistM: 1.25);
    expect(simplified.length, lessThan(path.length));
    expect(simplified.length, greaterThan(3));

    // Nearest simplified point to the geometric corner should be close.
    var best = double.infinity;
    for (final p in simplified) {
      final d = const Distance().as(LengthUnit.Meter, corner, p);
      if (d < best) best = d;
    }
    expect(best, lessThanOrEqualTo(2.5));
  });
}
