import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

enum ImplementMount { fixed, trailed }

/// Visual + swath geometry: GPS → hitch → axle → boom centre (inverted T).
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

/// Computes implement position. Trailed mode uses hitch articulation:
/// dθ/ds = sin(β) / L  where β = tractorHeading − trailerHeading.
class ImplementTracker {
  /// Reject per-step yaw spikes from GPS glitches (not a physics limit).
  static const double maxYawStepDeg = 18.0;

  double implementHeadingDeg = 0;
  LatLng? implementCenter;
  LatLng? hitchPivot;
  LatLng? trailerAxle;
  LatLng? _lastPivotPos;
  bool _hasHeading = false;
  double? _lastTractorHeadingDeg;

  bool get hasHeading => _hasHeading;

  void reset() {
    implementHeadingDeg = 0;
    implementCenter = null;
    hitchPivot = null;
    trailerAxle = null;
    _lastPivotPos = null;
    _hasHeading = false;
    _lastTractorHeadingDeg = null;
  }

  ImplementGeometry layout({
    required LatLng gpsPos,
    required double? gpsHeadingDeg,
    required double gpsToPivotM,
    required double gpsLateralOffsetM,
    required double hitchToAxleM,
    required double axleToBoomM,
    required double widthM,
    required double lateralOffsetM,
    required ImplementMount mount,
    bool integrateTrailer = true,
  }) {
    final hitchBar = hitchToAxleM.clamp(0.0, 80.0);
    final boomReach = axleToBoomM.clamp(0.0, 80.0);
    final w = widthM <= 0 ? 3.0 : widthM;
    if (gpsHeadingDeg != null) _lastTractorHeadingDeg = gpsHeadingDeg;
    final tractorH =
        gpsHeadingDeg ?? _lastTractorHeadingDeg ?? implementHeadingDeg;
    final pivot = _hitchFromGps(gpsPos, tractorH, gpsToPivotM, gpsLateralOffsetM);
    hitchPivot = pivot;

    double heading;
    if (mount == ImplementMount.fixed) {
      heading = tractorH;
      implementHeadingDeg = heading;
      _hasHeading = true;
      _lastPivotPos = pivot;
    } else if (integrateTrailer) {
      heading = _trailedHeading(
        pivot: pivot,
        gpsHeadingDeg: gpsHeadingDeg,
        tractorH: tractorH,
        hitchBar: hitchBar,
      );
    } else {
      if (!_hasHeading) {
        implementHeadingDeg = tractorH;
        _hasHeading = true;
      }
      heading = implementHeadingDeg;
    }

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
    trailerAxle = axle;

    var center = _offsetMeters(
      axle,
      behindEast * boomReach,
      behindNorth * boomReach,
    );

    if (lateralOffsetM.abs() > 1e-9) {
      center = _offsetMeters(
        center,
        rightEast * lateralOffsetM,
        rightNorth * lateralOffsetM,
      );
    }

    implementCenter = center;

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

  /// Hitch articulation: trailer yaw rate = sin(β) / L per metre hitch travel.
  double _trailedHeading({
    required LatLng pivot,
    required double? gpsHeadingDeg,
    required double tractorH,
    required double hitchBar,
  }) {
    if (!_hasHeading) {
      implementHeadingDeg = gpsHeadingDeg ?? tractorH;
      _hasHeading = true;
      _lastPivotPos = pivot;
      return implementHeadingDeg;
    }

    if (_lastPivotPos != null) {
      final ds = _distM(_lastPivotPos!, pivot);
      if (ds > 0.04) {
        final travelBearing = const Distance().bearing(_lastPivotPos!, pivot);
        final effTractorH = _effectiveTractorHeadingDeg(
          gpsHeadingDeg ?? tractorH,
          travelBearing,
        );
        final betaRad = _degToRad(
          _normalizeAngle(effTractorH - implementHeadingDeg),
        );
        final bar = hitchBar.clamp(0.5, 80.0);
        var dThetaDeg = (ds / bar) * math.sin(betaRad) * 180.0 / math.pi;
        dThetaDeg = dThetaDeg.clamp(-maxYawStepDeg, maxYawStepDeg);
        implementHeadingDeg = _normalizeAngle(implementHeadingDeg + dThetaDeg);
      }
    }

    _lastPivotPos = pivot;
    return implementHeadingDeg;
  }

  static double _effectiveTractorHeadingDeg(
    double tractorHeadingDeg,
    double travelBearingDeg,
  ) {
    final diff = _normalizeAngle(travelBearingDeg - tractorHeadingDeg);
    if (diff > 90 || diff < -90) return travelBearingDeg;
    return tractorHeadingDeg;
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

  static double _normalizeAngle(double deg) {
    var a = deg % 360;
    if (a > 180) a -= 360;
    if (a < -180) a += 360;
    return a;
  }

  static double _degToRad(double deg) => deg * math.pi / 180.0;

  static double _distM(LatLng a, LatLng b) =>
      const Distance().as(LengthUnit.Meter, a, b);

  static LatLng _offsetMeters(LatLng p, double eastM, double northM) {
    const rm = 111320.0;
    final cosLat = math.cos(p.latitude * math.pi / 180.0);
    return LatLng(
      p.latitude + northM / rm,
      p.longitude + eastM / (rm * cosLat),
    );
  }
}
