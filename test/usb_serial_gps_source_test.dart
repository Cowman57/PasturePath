import 'package:flutter_test/flutter_test.dart';
import 'package:tractorgps/services/gps/nmea_parser.dart';
import 'package:tractorgps/services/gps/usb_serial_gps_source.dart';

void main() {
  group('UsbSerialGpsSource sentence drain', () {
    test('processes multiple sentences packed in one chunk', () {
      final parser = NmeaParser();
      var fixes = 0;
      String? lastReject;

      void process(String line) {
        final r = parser.addLineDetailed(line);
        if (r.fix != null) fixes++;
        if (!r.isNoise) lastReject = r.rejectReason;
      }

      // GSV first, then GGA with fix — mimics 25 Hz USB packing.
      const chunk =
          '\$GAGSV,1,1,00,7*73\r'
          '\$GNGGA,092750.000,5321.6802,N,00630.8372,E,1,12,0.97,45.0,M,47.0,M,,*00\r\n';

      final buf = chunk.codeUnits;
      var i = 0;
      while (i < buf.length) {
        final start = buf.indexOf(0x24, i);
        if (start < 0) break;
        var end = -1;
        for (var j = start + 1; j < buf.length; j++) {
          if (buf[j] == 0x24 || buf[j] == 0x0D || buf[j] == 0x0A) {
            end = j;
            break;
          }
        }
        if (end < 0) break;
        final body = String.fromCharCodes(buf.sublist(start + 1, end));
        process('\$$body');
        i = buf[end] == 0x24 ? end : end + 1;
      }

      expect(fixes, 1);
      expect(lastReject, isNull);
    });
  });
}
