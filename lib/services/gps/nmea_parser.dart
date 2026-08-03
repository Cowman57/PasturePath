import '../../models/gps_fix.dart';

class NmeaParseResult {
  const NmeaParseResult({this.fix, this.rejectReason, this.isNoise = false});
  final GpsFix? fix;
  final String? rejectReason;

  /// True for GSV/GSA/etc. — diagnostics should not treat this as the main failure.
  final bool isNoise;
}

class _LatLonPair {
  const _LatLonPair(this.lat, this.lon, this.nextIndex);
  final double lat;
  final double lon;
  final int nextIndex;
}

/// Parses NMEA-0183 sentences into [GpsFix] updates.
class NmeaParser {
  double? _lat;
  double? _lon;
  double? _headingDeg;
  double? _speedMps;
  double? _hdop;
  int? _satellites;
  DateTime? _utc;

  void reset() {
    _lat = null;
    _lon = null;
    _headingDeg = null;
    _speedMps = null;
    _hdop = null;
    _satellites = null;
    _utc = null;
  }

  GpsFix? addLine(String raw) => addLineDetailed(raw).fix;

  NmeaParseResult addLineDetailed(String raw) {
    var line = raw.trim();
    if (line.isEmpty) {
      return const NmeaParseResult(rejectReason: 'empty', isNoise: true);
    }

    final dollar = line.indexOf('\$');
    if (dollar > 0) line = line.substring(dollar);
    if (!line.startsWith('\$') && !line.startsWith('!')) {
      return const NmeaParseResult(rejectReason: 'not NMEA', isNoise: true);
    }

    final star = line.lastIndexOf('*');
    final body = star >= 0 ? line.substring(0, star) : line;
    // Intentionally ignore checksum — many USB GPS modules emit bad ones.

    final fields = body.split(',');
    if (fields.isEmpty) {
      return const NmeaParseResult(rejectReason: 'no fields', isNoise: true);
    }

    var type = fields[0];
    if (type.startsWith('\$') || type.startsWith('!')) {
      type = type.substring(1);
    }
    if (type.length < 3) {
      return const NmeaParseResult(rejectReason: 'bad type', isNoise: true);
    }
    final sentence = type.substring(type.length - 3).toUpperCase();

    switch (sentence) {
      case 'RMC':
        return _parseRmc(fields);
      case 'GGA':
        return _parseGga(fields);
      case 'GLL':
        return _parseGll(fields);
      case 'VTG':
        _parseVtg(fields);
        return const NmeaParseResult(
          rejectReason: 'VTG (no position)',
          isNoise: true,
        );
      default:
        return NmeaParseResult(
          rejectReason: 'ignored $sentence',
          isNoise: true,
        );
    }
  }

  NmeaParseResult _parseRmc(List<String> f) {
    if (f.length < 4) {
      return const NmeaParseResult(rejectReason: 'RMC short');
    }

    final status = f[2].trim().toUpperCase();
    if (status == 'V') {
      return const NmeaParseResult(rejectReason: 'RMC no fix yet');
    }
    if (status.isNotEmpty && status != 'A' && status != 'D') {
      return NmeaParseResult(rejectReason: 'RMC void ($status)');
    }

    final latRaw = f.length > 3 ? f[3].trim() : '';
    final lonRaw = f.length > 5 ? f[5].trim() : '';
    if (latRaw.isEmpty || lonRaw.isEmpty) {
      return const NmeaParseResult(rejectReason: 'RMC no fix yet');
    }

    final pair = _readLatLon(f, 3);
    if (pair == null) {
      return NmeaParseResult(
        rejectReason: 'RMC bad lat/lon ($latRaw, $lonRaw)',
      );
    }

    _lat = pair.lat;
    _lon = pair.lon;
    var i = pair.nextIndex;

    final knots = i < f.length ? double.tryParse(f[i].trim()) : null;
    if (knots != null && knots >= 0) _speedMps = knots * 0.514444;
    i++;
    final course = i < f.length ? double.tryParse(f[i].trim()) : null;
    if (course != null && course >= 0) _headingDeg = course % 360.0;
    i++;
    final date = i < f.length ? f[i].trim() : '';
    _utc = _parseUtc(f[1], date) ??
        _parseUtcTimeOnly(f[1]) ??
        DateTime.now().toUtc();

    final fix = _emit();
    if (fix == null) {
      return const NmeaParseResult(rejectReason: 'RMC out of range');
    }
    return NmeaParseResult(fix: fix);
  }

  NmeaParseResult _parseGga(List<String> f) {
    if (f.length < 7) {
      return const NmeaParseResult(rejectReason: 'GGA short');
    }

    final latRaw = f[2].trim();
    final lonProbe = f.length > 4 ? f[4].trim() : '';
    final lonRawCompact = f.length > 3 ? f[3].trim() : '';
    final qualityRawStd = f[6].trim();
    final qualityStd = int.tryParse(qualityRawStd) ?? 0;

    // No lock: GGA often has empty coordinate fields.
    final looksEmpty = latRaw.isEmpty ||
        (lonProbe.isEmpty && lonRawCompact.isEmpty);
    if (looksEmpty) {
      return NmeaParseResult(
        rejectReason: qualityStd <= 0
            ? 'GGA no fix yet (quality $qualityRawStd)'
            : 'GGA missing coordinates',
      );
    }

    final pair = _readLatLon(f, 2);
    if (pair == null) {
      final latHemi = f.length > 3 ? f[3].trim() : '';
      final lonRaw = f.length > 4 ? f[4].trim() : '';
      final lonHemi = f.length > 5 ? f[5].trim() : '';
      return NmeaParseResult(
        rejectReason: 'GGA bad lat/lon ($latRaw $latHemi, $lonRaw $lonHemi)',
      );
    }

    final qIdx = pair.nextIndex;
    final qualityRaw = qIdx < f.length ? f[qIdx].trim() : qualityRawStd;
    final quality = int.tryParse(qualityRaw) ?? qualityStd;
    if (qualityRaw.isNotEmpty && quality <= 0) {
      return const NmeaParseResult(rejectReason: 'GGA no fix yet');
    }

    _lat = pair.lat;
    _lon = pair.lon;
    if (qIdx + 1 < f.length) {
      final sats = int.tryParse(f[qIdx + 1].trim());
      if (sats != null && sats >= 0) _satellites = sats;
    }
    if (qIdx + 2 < f.length) {
      _hdop = double.tryParse(f[qIdx + 2].trim());
    }
    final t = _parseUtcTimeOnly(f[1]);
    if (t != null) _utc = t;

    final fix = _emit();
    if (fix == null) {
      return const NmeaParseResult(rejectReason: 'GGA out of range');
    }
    return NmeaParseResult(fix: fix);
  }

  NmeaParseResult _parseGll(List<String> f) {
    if (f.length < 3) {
      return const NmeaParseResult(rejectReason: 'GLL short');
    }
    final pair = _readLatLon(f, 1);
    if (pair == null) {
      return const NmeaParseResult(rejectReason: 'GLL bad lat/lon');
    }
    var i = pair.nextIndex;
    final time = i < f.length ? f[i].trim() : '';
    i++;
    final status = i < f.length ? f[i].trim().toUpperCase() : 'A';
    if (status.isNotEmpty && status != 'A' && status != 'D') {
      return NmeaParseResult(rejectReason: 'GLL void ($status)');
    }
    _lat = pair.lat;
    _lon = pair.lon;
    final t = _parseUtcTimeOnly(time);
    if (t != null) _utc = t;
    final fix = _emit();
    if (fix == null) {
      return const NmeaParseResult(rejectReason: 'GLL out of range');
    }
    return NmeaParseResult(fix: fix);
  }

  void _parseVtg(List<String> f) {
    if (f.length < 2) return;
    final course = double.tryParse(f[1].trim());
    if (course != null && course >= 0) {
      _headingDeg = course % 360.0;
    }
    if (f.length > 7) {
      final kmh = double.tryParse(f[7].trim());
      if (kmh != null && kmh >= 0) {
        _speedMps = kmh / 3.6;
        return;
      }
    }
    if (f.length > 5) {
      final knots = double.tryParse(f[5].trim());
      if (knots != null && knots >= 0) {
        _speedMps = knots * 0.514444;
      }
    }
  }

  GpsFix? _emit() {
    final lat = _lat;
    final lon = _lon;
    if (lat == null || lon == null) return null;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return GpsFix(
      latitude: lat,
      longitude: lon,
      timestamp: _utc ?? DateTime.now().toUtc(),
      headingDeg: _headingDeg,
      speedMps: _speedMps,
      hdop: _hdop,
      satellites: _satellites,
      accuracyM: _hdop != null ? _hdop! * 5.0 : null,
    );
  }

  /// Supports standard `ddmm.mm,H` and compact `ddmm.mmH` pairs.
  static _LatLonPair? _readLatLon(List<String> f, int start) {
    if (start >= f.length) return null;
    final a = f[start].trim();
    if (a.isEmpty) return null;

    final compactLat = _parseCombined(a, lat: true);
    if (compactLat != null && start + 1 < f.length) {
      final compactLon = _parseCombined(f[start + 1].trim(), lat: false);
      if (compactLon != null) {
        return _LatLonPair(compactLat, compactLon, start + 2);
      }
    }

    if (start + 3 >= f.length) return null;
    final lat = _parseDm(a, f[start + 1].trim(), lat: true);
    final lon =
        _parseDm(f[start + 2].trim(), f[start + 3].trim(), lat: false);
    if (lat == null || lon == null) return null;
    return _LatLonPair(lat, lon, start + 4);
  }

  static double? _parseCombined(String raw, {required bool lat}) {
    if (raw.length < 4) return null;
    final hemi = raw[raw.length - 1].toUpperCase();
    final ok = lat ? (hemi == 'N' || hemi == 'S') : (hemi == 'E' || hemi == 'W');
    if (!ok) return null;
    return _parseDm(raw.substring(0, raw.length - 1), hemi, lat: lat);
  }

  /// ddmm.mmm / dddmm.mmm, or decimal degrees, with hemisphere.
  static double? _parseDm(String value, String hemi, {required bool lat}) {
    if (value.isEmpty || hemi.isEmpty) return null;
    final hemiU = hemi.toUpperCase();
    if (lat) {
      if (hemiU != 'N' && hemiU != 'S') return null;
    } else {
      if (hemiU != 'E' && hemiU != 'W') return null;
    }
    final neg = hemiU == 'S' || hemiU == 'W';

    final cleaned = value.trim();
    if (cleaned.isEmpty) return null;

    final degDigits = lat ? 2 : 3;
    final abs = cleaned.startsWith('-') ? cleaned.substring(1) : cleaned;
    final absDot = abs.indexOf('.');
    final absInt = absDot >= 0 ? abs.substring(0, absDot) : abs;

    double? result;
    if (absInt.length >= degDigits) {
      final d = double.tryParse(abs.substring(0, degDigits));
      final mStr = abs.substring(degDigits);
      final m = mStr.isEmpty ? 0.0 : double.tryParse(mStr);
      if (d != null && m != null && m >= 0 && m < 60) {
        result = d + m / 60.0;
      }
    }

    // Decimal-degrees fallback when dm parse fails (e.g. "36.85000")
    result ??= double.tryParse(cleaned);

    if (result == null) return null;
    if (result.abs() > (lat ? 90.0 : 180.0)) return null;
    return neg ? -result.abs() : result.abs();
  }

  static DateTime? _parseUtc(String hhmmss, String ddmmyy) {
    final t = _parseHms(hhmmss);
    if (t == null || ddmmyy.length < 6) return null;
    final day = int.tryParse(ddmmyy.substring(0, 2));
    final month = int.tryParse(ddmmyy.substring(2, 4));
    final yy = int.tryParse(ddmmyy.substring(4, 6));
    if (day == null || month == null || yy == null) return null;
    final year = yy >= 80 ? 1900 + yy : 2000 + yy;
    try {
      return DateTime.utc(year, month, day, t.$1, t.$2, t.$3, t.$4);
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parseUtcTimeOnly(String hhmmss) {
    final t = _parseHms(hhmmss);
    if (t == null) return null;
    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day, t.$1, t.$2, t.$3, t.$4);
  }

  static (int, int, int, int)? _parseHms(String hhmmss) {
    final s = hhmmss.trim();
    if (s.length < 6) return null;
    final h = int.tryParse(s.substring(0, 2));
    final m = int.tryParse(s.substring(2, 4));
    final secPart = double.tryParse(s.substring(4));
    if (h == null || m == null || secPart == null) return null;
    final sec = secPart.floor();
    final ms = ((secPart - sec) * 1000).round();
    return (h, m, sec, ms);
  }
}
