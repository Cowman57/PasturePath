import 'dart:convert';
import 'dart:typed_data';
import 'package:latlong2/latlong.dart';

import '../models/paddock.dart';
import 'dart:math' as math;
import 'geometry.dart';

class ParsedResult {
  final List<Paddock> paddocks;
  final String? error;
  ParsedResult({required this.paddocks, this.error});
}

class GeoJsonParser {
  static ParsedResult parseBytes(Uint8List bytes) {
    try {
      final txt = utf8.decode(bytes);
      final data = json.decode(txt);
      if (data is! Map || data['type'] != 'FeatureCollection') {
        return ParsedResult(paddocks: const [], error: 'Not a FeatureCollection');
      }
      final feats = (data['features'] as List?) ?? const [];
      final out = <Paddock>[];
      for (final f in feats) {
        if (f is! Map) continue;
        final props = (f['properties'] as Map?) ?? const {};
        final geom = (f['geometry'] as Map?) ?? const {};
        if (geom['type'] != 'Polygon') continue;
        final coords = (geom['coordinates'] as List?) ?? const [];
        if (coords.isEmpty) continue;

        List<LatLng> _toRing(List ring) {
          return ring.map<LatLng>((c) {
            final lon = (c as List)[0] * 1.0;
            final lat = (c as List)[1] * 1.0;
            return LatLng(lat, lon);
          }).toList();
        }

        final outer = _toRing(coords.first as List);
        // drop duplicate last point if closed
        if (outer.length >= 2 && outer.first == outer.last) { outer.removeLast(); }
        final holes = <List<LatLng>>[];
        for (int i = 1; i < coords.length; i++) {
          final h = _toRing(coords[i] as List);
          if (h.length >= 2 && h.first == h.last) { h.removeLast(); }
          holes.add(h);
        }

        final rawName = props['Name'] ?? props['name'] ?? props['PDK'] ?? props['pdk'] ?? 'Paddock';
        final name = '$rawName'.trim();
        final areaProp = props['Area,ha'] ?? props['areaHa'] ?? props['Area (ha)'] ?? props['area'];
        final areaHa = areaProp is num ? areaProp.toDouble() : _areaHa(outer, holes);
        final label = bestInteriorLabelPoint(outer, holes);

        out.add(Paddock(name: name, outer: outer, holes: holes, areaHa: areaHa, labelPoint: label));
      }
      return ParsedResult(paddocks: out);
    } catch (e) {
      return ParsedResult(paddocks: const [], error: e.toString());
    }
  }
}

double _areaHa(List<LatLng> outer, List<List<LatLng>> holes) {
  double ringAreaM2(List<LatLng> ring) {
    if (ring.length < 3) return 0.0;
    final c = _centroid(ring);
    const R = 6371000.0;
    double toX(LatLng p) => (p.longitude - c.longitude) * (3.141592653589793 / 180.0) * R * math.cos(c.latitude * 3.141592653589793 / 180.0);
    double toY(LatLng p) => (p.latitude  - c.latitude)  * (3.141592653589793 / 180.0) * R;
    double sum = 0.0;
    for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = toX(ring[i]), yi = toY(ring[i]);
      final xj = toX(ring[j]), yj = toY(ring[j]);
      sum += (xj * yi - xi * yj);
    }
    return 0.5 * sum.abs();
  }
  double a = ringAreaM2(outer);
  for (final h in holes) { a -= ringAreaM2(h); }
  return (a / 10000.0).abs();
}


LatLng _centroid(List<LatLng> ring) {
  double x = 0, y = 0;
  for (final p in ring) { x += p.latitude; y += p.longitude; }
  return LatLng(x / ring.length, y / ring.length);
}

