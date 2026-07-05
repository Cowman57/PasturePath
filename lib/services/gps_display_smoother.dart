import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Interpolates GPS display between fixes. [smoothness] 0 = snap; 1 = animate
/// over one measured fix interval (typically ~1 s lag when moving).
class GpsDisplaySmoother {
  GpsDisplaySmoother({this.smoothness = 0.0});

  /// 0 = no smoothing, 1 = animation length equals fix interval.
  double smoothness;

  /// Rolling estimate of milliseconds between GPS fixes.
  double intervalMs = 1000.0;

  LatLng? _displayPos;
  double? _displayHeading;

  LatLng? _fromPos;
  LatLng? _toPos;
  double? _fromHeading;
  double? _toHeading;
  DateTime? _animStart;
  int _animDurationMs = 0;
  DateTime? _lastFixWallTime;

  LatLng? get displayPosition => _displayPos;
  double? get displayHeading => _displayHeading;
  bool get isAnimating =>
      smoothness > 0 &&
      _animStart != null &&
      _animDurationMs > 0 &&
      _fromPos != null &&
      _toPos != null &&
      _progress(DateTime.now()) < 1.0;

  void onFix({
    required LatLng position,
    double? headingDeg,
    bool snapDisplay = false,
  }) {
    _updateInterval(DateTime.now());

    if (_displayPos != null &&
        _animStart != null &&
        _animDurationMs > 0 &&
        _fromPos != null &&
        _toPos != null) {
      final t = _progress(DateTime.now());
      _displayPos = _lerpLatLng(_fromPos!, _toPos!, t);
      _displayHeading = _lerpHeading(_fromHeading, _toHeading, t);
    }

    _toPos = position;
    _toHeading = headingDeg;

    if (smoothness <= 0 || snapDisplay || _displayPos == null) {
      _displayPos = position;
      _displayHeading = headingDeg;
      _animStart = null;
      _animDurationMs = 0;
      return;
    }

    _fromPos = _displayPos!;
    _fromHeading = _displayHeading ?? headingDeg;
    _toHeading ??= _fromHeading;

    _animDurationMs = math.max(50, (smoothness * intervalMs).round());
    _animStart = DateTime.now();
  }

  /// Returns true while the animation is still running.
  bool tick(DateTime now) {
    if (_displayPos == null ||
        _toPos == null ||
        smoothness <= 0 ||
        _animStart == null ||
        _animDurationMs <= 0 ||
        _fromPos == null) {
      return false;
    }

    final t = _progress(now);
    _displayPos = _lerpLatLng(_fromPos!, _toPos!, t);
    _displayHeading = _lerpHeading(_fromHeading, _toHeading, t);
    return t < 1.0;
  }

  void snapToTarget() {
    if (_toPos != null) _displayPos = _toPos;
    if (_toHeading != null) _displayHeading = _toHeading;
    _animStart = null;
    _animDurationMs = 0;
  }

  void _updateInterval(DateTime now) {
    if (_lastFixWallTime != null) {
      final dt = now.difference(_lastFixWallTime!).inMilliseconds.toDouble();
      if (dt >= 50 && dt <= 8000) {
        intervalMs = intervalMs * 0.7 + dt * 0.3;
      }
    }
    _lastFixWallTime = now;
  }

  double _progress(DateTime now) {
    if (_animStart == null || _animDurationMs <= 0) return 1.0;
    final elapsed = now.difference(_animStart!).inMilliseconds;
    final linear = (elapsed / _animDurationMs).clamp(0.0, 1.0);
    return _smoothstep(linear);
  }

  /// Ease-in-out so motion accelerates and decelerates between fixes.
  static double _smoothstep(double t) => t * t * (3 - 2 * t);

  static LatLng _lerpLatLng(LatLng a, LatLng b, double t) {
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  static double? _lerpHeading(double? a, double? b, double t) {
    if (a == null) return b;
    if (b == null) return a;
    var delta = (b - a) % 360;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    return (a + delta * t) % 360;
  }
}
