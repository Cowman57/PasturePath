import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Visual + swath geometry: GPS → hitch → axle → boom centre.
class ImplementGeometry {
  final LatLng gpsPos;
  final LatLng hitchPivot;
  final LatLng trailerAxle;
  final LatLng implementCenter;
  final double implementHeadingDeg;
  final LatLng boomLeft;
  final LatLng boomRight;

  const ImplementGeometry({
    required this.gpsPos,
    required this.hitchPivot,
    required this.trailerAxle,
    required this.implementCenter,
    required this.implementHeadingDeg,
    required this.boomLeft,
    required this.boomRight,
  });
}

/// Computes implement position from GPS, heading, and tool dimensions.
class ImplementTracker {
  double implementHeadingDeg = 0;
  LatLng? implementCenter;
  LatLng? hitchPivot;
  LatLng? trailerAxle;

  void reset() {
    implementHeadingDeg = 0;
    implementCenter = null;
    hitchPivot = null;
    trailerAxle = null;
  }

  /// Pure geometry — does not mutate tracker state (safe for swath projection).
  static ImplementGeometry compute({
    required LatLng gpsPos,
    required double headingDeg,
    required double gpsToPivotM,
    required double gpsLateralOffsetM,
    required double hitchToAxleM,
    required double widthM,
    required double lateralOffsetM,
  }) {
    final hitchBar = hitchToAxleM.clamp(0.0, 80.0);
    final w = widthM <= 0 ? 3.0 : widthM;
    final heading = headingDeg;

    final pivot = _hitchFromGps(gpsPos, heading, gpsToPivotM, gpsLateralOffsetM);

    final hRad = heading * math.pi / 180.0;
    final behindEast = -math.sin(hRad);
    final behindNorth = -math.cos(hRad);
    final rightEast = math.cos(hRad);
    final rightNorth = -math.sin(hRad);

    final axle = _offsetMeters(
      pivot,
      behindEast * hitchBar,
      behindNorth * hitchBar,
    );

    var center = axle;
    if (lateralOffsetM.abs() > 1e-9) {
      center = _offsetMeters(
        center,
        rightEast * lateralOffsetM,
        rightNorth * lateralOffsetM,
      );
    }

    final perpRad = (heading + 90.0) * math.pi / 180.0;
    final half = w * 0.5;
    final perpEast = math.sin(perpRad);
    final perpNorth = math.cos(perpRad);
    final left = _offsetMeters(center, -perpEast * half, -perpNorth * half);
    final right = _offsetMeters(center, perpEast * half, perpNorth * half);

    return ImplementGeometry(
      gpsPos: gpsPos,
      hitchPivot: pivot,
      trailerAxle: axle,
      implementCenter: center,
      implementHeadingDeg: heading,
      boomLeft: left,
      boomRight: right,
    );
  }

  ImplementGeometry layout({
    required LatLng gpsPos,
    required double? gpsHeadingDeg,
    required double gpsToPivotM,
    required double gpsLateralOffsetM,
    required double hitchToAxleM,
    required double widthM,
    required double lateralOffsetM,
  }) {
    final heading = gpsHeadingDeg ?? implementHeadingDeg;
    final geom = compute(
      gpsPos: gpsPos,
      headingDeg: heading,
      gpsToPivotM: gpsToPivotM,
      gpsLateralOffsetM: gpsLateralOffsetM,
      hitchToAxleM: hitchToAxleM,
      widthM: widthM,
      lateralOffsetM: lateralOffsetM,
    );
    implementHeadingDeg = heading;
    hitchPivot = geom.hitchPivot;
    trailerAxle = geom.trailerAxle;
    implementCenter = geom.implementCenter;
    return geom;
  }

  /// Hitch behind GPS along heading; [gpsLateralOffsetM] + = GPS right of hitch.
  static LatLng _hitchFromGps(
    LatLng gps,
    double headingDeg,
    double gpsToPivotM,
    double gpsLateralOffsetM,
  ) {
    final hRad = headingDeg * math.pi / 180.0;
    final behindEast = -math.sin(hRad);
    final behindNorth = -math.cos(hRad);
    final rightEast = math.cos(hRad);
    final rightNorth = -math.sin(hRad);
    return _offsetMeters(
      gps,
      behindEast * gpsToPivotM - rightEast * gpsLateralOffsetM,
      behindNorth * gpsToPivotM - rightNorth * gpsLateralOffsetM,
    );
  }

  static LatLng _offsetMeters(LatLng p, double eastM, double northM) {
    const rm = 111320.0;
    final cosLat = math.cos(p.latitude * math.pi / 180.0);
    return LatLng(
      p.latitude + northM / rm,
      p.longitude + eastM / (rm * cosLat),
    );
  }
}
