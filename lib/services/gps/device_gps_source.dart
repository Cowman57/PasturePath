import 'dart:async';
import 'dart:io' as io;

import 'package:geolocator/geolocator.dart';

import '../../models/gps_fix.dart';
import 'gps_source.dart';

class DeviceGpsSource implements GpsSource {
  StreamController<GpsFix>? _controller;
  StreamSubscription<Position>? _sub;

  @override
  String get label => 'Device GPS';

  @override
  Stream<GpsFix> get fixes {
    _controller ??= StreamController<GpsFix>.broadcast();
    return _controller!.stream;
  }

  /// Ensures location services/permission. Returns an error message, or null if OK.
  static Future<String?> ensurePermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return 'Please enable Location Services';
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return 'Location permission required';
    }
    return null;
  }

  @override
  Future<void> start() async {
    await stop();
    _controller ??= StreamController<GpsFix>.broadcast();

    final err = await ensurePermission();
    if (err != null) {
      throw StateError(err);
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 10),
        ),
      );
      _emit(pos);
    } catch (_) {}

    final LocationSettings settings;
    if (io.Platform.isAndroid) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 100),
        forceLocationManager: true,
      );
    } else if (io.Platform.isIOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        allowBackgroundLocationUpdates: false,
        pauseLocationUpdatesAutomatically: false,
        activityType: ActivityType.otherNavigation,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );
    }

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_emit);
  }

  void _emit(Position p) {
    final c = _controller;
    if (c == null || c.isClosed) return;
    c.add(GpsFix(
      latitude: p.latitude,
      longitude: p.longitude,
      timestamp: p.timestamp,
      headingDeg: p.heading >= 0 ? p.heading : null,
      speedMps: p.speed >= 0 ? p.speed : null,
      accuracyM: p.accuracy >= 0 ? p.accuracy : null,
    ));
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller?.close();
    _controller = null;
  }
}
