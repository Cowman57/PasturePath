import 'package:flutter_test/flutter_test.dart';
import 'package:tractorgps/services/gps/nmea_parser.dart';

String _cs(String body) {
  var x = 0;
  for (final c in body.codeUnits) {
    x ^= c;
  }
  return x.toRadixString(16).toUpperCase().padLeft(2, '0');
}

String nmea(String body) => '\$$body*${_cs(body)}';

void main() {
  group('NmeaParser', () {
    test('parses RMC fix with lat/lon/speed/course', () {
      final p = NmeaParser();
      final line = nmea(
        'GPRMC,123519.00,A,3650.0000,S,17445.0000,E,5.0,90.0,160326,,,A',
      );
      final fix = p.addLine(line);
      expect(fix, isNotNull);
      expect(fix!.latitude, closeTo(-36.833333, 0.0001));
      expect(fix.longitude, closeTo(174.75, 0.0001));
      expect(fix.speedMps, closeTo(5.0 * 0.514444, 0.001));
      expect(fix.headingDeg, closeTo(90.0, 0.01));
    });

    test('parses compact RMC with hemisphere glued to coordinates', () {
      final p = NmeaParser();
      final fix = p.addLine(nmea(
        'GPRMC,123519.00,A,3650.0000S,17445.0000E,5.0,90.0,160326,,,A',
      ));
      expect(fix, isNotNull);
      expect(fix!.latitude, closeTo(-36.833333, 0.0001));
      expect(fix.longitude, closeTo(174.75, 0.0001));
    });

    test('parses GGA despite bad checksum', () {
      final p = NmeaParser();
      final fix = p.addLine(
        '\$GNGGA,123519.00,3650.0000,S,17445.0000,E,1,08,0.9,10.0,M,0.0,M,,*00',
      );
      expect(fix, isNotNull);
      expect(fix!.latitude, closeTo(-36.833333, 0.0001));
      expect(fix.longitude, closeTo(174.75, 0.0001));
    });

    test('rejects RMC with void status', () {
      final p = NmeaParser();
      final fix = p.addLine(nmea(
        'GPRMC,123519.00,V,3650.0000,S,17445.0000,E,5.0,90.0,160326,,,A',
      ));
      expect(fix, isNull);
      expect(p.addLineDetailed(nmea(
        'GPRMC,123519.00,V,3650.0000,S,17445.0000,E,5.0,90.0,160326,,,A',
      )).rejectReason, contains('no fix'));
    });

    test('parses GGA and carries heading from prior VTG', () {
      final p = NmeaParser();
      expect(p.addLine(nmea('GPVTG,45.0,T,,M,3.0,N,5.556,K')), isNull);
      final fix = p.addLine(nmea(
        'GNGGA,123519.00,3650.0000,S,17445.0000,E,1,08,0.9,10.0,M,0.0,M,,',
      ));
      expect(fix, isNotNull);
      expect(fix!.headingDeg, closeTo(45.0, 0.01));
      expect(fix.speedMps, closeTo(5.556 / 3.6, 0.01));
      expect(fix.hdop, closeTo(0.9, 0.01));
      expect(fix.satellites, 8);
      expect(fix.accuracyM, closeTo(4.5, 0.01));
    });

    test('parses leading-zero longitude', () {
      final p = NmeaParser();
      final fix = p.addLine(nmea(
        'GPGGA,092750.000,0113.7276,N,10339.0121,E,1,8,1.03,61.7,M,55.2,M,,',
      ));
      expect(fix, isNotNull);
      expect(fix!.latitude, closeTo(1.228793, 0.0001));
      expect(fix.longitude, closeTo(103.650201, 0.0001));
    });

    test('rejects empty GGA as no fix yet', () {
      final p = NmeaParser();
      final r = p.addLineDetailed(nmea(
        'GNGGA,123519.00,,,,,0,00,99.99,,,,,,',
      ));
      expect(r.fix, isNull);
      expect(r.rejectReason, contains('no fix'));
    });

    test('accepts line without checksum', () {
      final p = NmeaParser();
      final fix = p.addLine(
        '\$GPRMC,123519.00,A,3650.0000,S,17445.0000,E,5.0,90.0,160326,,,A',
      );
      expect(fix, isNotNull);
    });
  });
}
