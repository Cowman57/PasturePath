import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/implement_kinematics.dart';

LatLng _advance(LatLng from, double headingDeg, double meters) {
  const rm = 111320.0;
  final hRad = headingDeg * math.pi / 180.0;
  final northM = math.cos(hRad) * meters;
  final eastM = math.sin(hRad) * meters;
  final cosLat = math.cos(from.latitude * math.pi / 180.0);
  return LatLng(
    from.latitude + northM / rm,
    from.longitude + eastM / (rm * cosLat),
  );
}

void main() {
  test('boom centre sits behind GPS by hitch length plus fixed pivot offset', () {
    const origin = LatLng(-37.67, 175.68);
    final tracker = ImplementTracker();

    final geom = tracker.layout(
      gpsPos: origin,
      gpsHeadingDeg: 0,
      gpsToPivotM: 0,
      gpsLateralOffsetM: 0,
      hitchToAxleM: 3,
      widthM: 3,
      lateralOffsetM: 0,
    );

    final behindM = const Distance().as(
      LengthUnit.Meter,
      origin,
      geom.implementCenter,
    );
    expect(behindM, closeTo(3, 0.5));
    expect(geom.implementHeadingDeg, 0);
  });

  test('lateral offsets shift boom sideways', () {
    const origin = LatLng(-37.67, 175.68);
    final tracker = ImplementTracker();

    final centred = tracker.layout(
      gpsPos: origin,
      gpsHeadingDeg: 0,
      gpsToPivotM: 0,
      gpsLateralOffsetM: 0,
      hitchToAxleM: 3,
      widthM: 3,
      lateralOffsetM: 0,
    );

    tracker.reset();
    final offset = tracker.layout(
      gpsPos: origin,
      gpsHeadingDeg: 0,
      gpsToPivotM: 0,
      gpsLateralOffsetM: 0,
      hitchToAxleM: 3,
      widthM: 3,
      lateralOffsetM: 1.5,
    );

    final lateralM = const Distance().as(
      LengthUnit.Meter,
      centred.implementCenter,
      offset.implementCenter,
    );
    expect(lateralM, closeTo(1.5, 0.6));
  });

  test('heading follows GPS through a corner', () {
    const origin = LatLng(-37.67, 175.68);
    final tracker = ImplementTracker();
    var gps = origin;
    var heading = 0.0;

    for (var i = 0; i < 20; i++) {
      if (i >= 5) heading += 9.0;
      gps = _advance(gps, heading, 0.5);
      tracker.layout(
        gpsPos: gps,
        gpsHeadingDeg: heading,
        gpsToPivotM: 0,
        gpsLateralOffsetM: 0,
        hitchToAxleM: 3,
        widthM: 3,
        lateralOffsetM: 0,
      );
    }

    expect(tracker.implementHeadingDeg, closeTo(heading, 0.1));
  });

  test('compute uses travel bearing without mutating tracker', () {
    const gps = LatLng(-37.67, 175.68);
    final tracker = ImplementTracker();
    tracker.layout(
      gpsPos: gps,
      gpsHeadingDeg: 0,
      gpsToPivotM: 0,
      gpsLateralOffsetM: 0,
      hitchToAxleM: 3,
      widthM: 3,
      lateralOffsetM: 0,
    );
    final savedCenter = tracker.implementCenter!;

    final projected = ImplementTracker.compute(
      gpsPos: gps,
      headingDeg: 90,
      gpsToPivotM: 0,
      gpsLateralOffsetM: 0,
      hitchToAxleM: 3,
      widthM: 3,
      lateralOffsetM: 0,
    );

    expect(tracker.implementCenter, savedCenter);
    expect(
      const Distance().as(LengthUnit.Meter, savedCenter, projected.implementCenter),
      greaterThan(1.0),
    );
  });
}
