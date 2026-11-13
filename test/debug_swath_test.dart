import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

void main() {
  group('buildSwathRingsFromPath', () {
    const swathWidthM = 20.0;

    // ~5 m GPS spacing over ~200 m. Spacing matters: splitPathAtJumps drops
    // anything with >40 m between consecutive fixes, which would yield no rings.
    final path = [
      for (var i = 0; i <= 40; i++) LatLng(-37.0 - i * 0.000045, 175.0),
    ];

    test('creates a polygon ring for a continuous forward path', () {
      final rings = buildSwathRingsFromPath(path, swathWidthM);

      expect(rings, isNotEmpty);
      for (final ring in rings) {
        expect(
          ring.length,
          greaterThanOrEqualTo(3),
          reason: 'every swath ring must be a valid polygon',
        );
      }
    });

    test('ring points stay within the swath width of the path', () {
      final rings = buildSwathRingsFromPath(path, swathWidthM);
      expect(rings, isNotEmpty);

      for (final ring in rings) {
        for (final p in ring) {
          expect(
            distancePointToPolylineMeters(p, path),
            lessThanOrEqualTo(swathWidthM),
            reason: 'ring offset must not exceed the swath width',
          );
        }
      }
    });

    test('returns no rings for degenerate input', () {
      expect(buildSwathRingsFromPath(const [], swathWidthM), isEmpty);
      expect(
        buildSwathRingsFromPath([const LatLng(-37.0, 175.0)], swathWidthM),
        isEmpty,
      );
    });
  });
}
