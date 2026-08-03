import '../../models/gps_fix.dart';

enum GpsInputMode {
  /// Prefer USB serial when a device is present, else device GPS.
  auto,
  device,
  usb,
}

extension GpsInputModeX on GpsInputMode {
  String get prefsValue => name;

  static GpsInputMode fromPrefs(String? value) {
    switch (value) {
      case 'device':
        return GpsInputMode.device;
      case 'usb':
        return GpsInputMode.usb;
      case 'auto':
      default:
        return GpsInputMode.auto;
    }
  }

  String get label {
    switch (this) {
      case GpsInputMode.auto:
        return 'Auto (USB if connected)';
      case GpsInputMode.device:
        return 'Device GPS';
      case GpsInputMode.usb:
        return 'USB serial';
    }
  }
}

enum GpsActiveSource { none, device, usb }

/// Common interface for a stream of [GpsFix] values.
abstract class GpsSource {
  Stream<GpsFix> get fixes;
  Future<void> start();
  Future<void> stop();
  String get label;
}
