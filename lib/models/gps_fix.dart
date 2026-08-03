/// A single GNSS fix from any input source (device GPS or USB NMEA).
class GpsFix {
  const GpsFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.headingDeg,
    this.speedMps,
    this.accuracyM,
    this.hdop,
    this.satellites,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;

  /// Course over ground in degrees [0, 360). Null if unknown.
  final double? headingDeg;

  /// Ground speed in metres per second. Null if unknown.
  final double? speedMps;

  final double? accuracyM;
  final double? hdop;

  /// Satellites used in the navigation solution (e.g. GGA numSV).
  final int? satellites;

  bool get hasHeading => headingDeg != null;
  bool get hasSpeed => speedMps != null && speedMps! >= 0;
}
