import 'package:latlong2/latlong.dart';
import 'dart:math' as math;

/// Ray-casting point-in-polygon with holes.
bool pointInPolygon(LatLng p, List<LatLng> outer, List<List<LatLng>> holes) {
  if (!_inRing(p, outer)) return false;
  for (final h in holes) {
    if (_inRing(p, h)) return false;
  }
  return true;
}

bool _inRing(LatLng p, List<LatLng> ring) {
  bool inside = false;
  for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude;
    final xj = ring[j].longitude, yj = ring[j].latitude;
    final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
        (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi + 1e-12) + xi);
    if (intersect) inside = !inside;
  }
  return inside;
}

/// Distance from point P to a polyline (list of LatLng). Returns meters (approx).
double distancePointToPolylineMeters(LatLng p, List<LatLng> line) {
  if (line.length < 2) return double.infinity;
  double best = double.infinity;
  for (int i = 0; i < line.length - 1; i++) {
    best = math.min(best, _distPointToSegMeters(p, line[i], line[i + 1]));
  }
  return best;
}

double _distPointToSegMeters(LatLng p, LatLng a, LatLng b) {
  // Convert small area to planar meters
  const Rm = 111320.0;
  final lat0 = ((a.latitude + b.latitude) * 0.5) * math.pi / 180.0;
  final ax = a.longitude * Rm * math.cos(lat0);
  final ay = a.latitude * Rm;
  final bx = b.longitude * Rm * math.cos(lat0);
  final by = b.latitude * Rm;
  final px = p.longitude * Rm * math.cos(lat0);
  final py = p.latitude * Rm;

  final vx = bx - ax, vy = by - ay;
  final wx = px - ax, wy = py - ay;
  final c1 = vx * wx + vy * wy;
  if (c1 <= 0) return math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
  final c2 = vx * vx + vy * vy;
  if (c2 <= c1) return math.sqrt((px - bx) * (px - bx) + (py - by) * (py - by));
  final t = c1 / c2;
  final hx = ax + t * vx, hy = ay + t * vy;
  return math.sqrt((px - hx) * (px - hx) + (py - hy) * (py - hy));
}

/// Clip a long AB line to a polygon with holes (sample-based exactness).
/// Returns list of segments after clipping.
List<List<LatLng>> clipLineABToPolygonExact(
    LatLng a,
    LatLng b,
    List<LatLng> outer,
    List<List<LatLng>> holes,
    ) {
  const samples = 1200; // higher density for tidy boundary intersections
  final out = <List<LatLng>>[];
  var seg = <LatLng>[];

  for (int i = 0; i <= samples; i++) {
    final t = i / samples;
    final p = LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
    if (pointInPolygon(p, outer, holes)) {
      seg.add(p);
    } else {
      if (seg.length >= 2) out.add(seg);
      seg = <LatLng>[];
    }
  }
  if (seg.length >= 2) out.add(seg);
  return out;
}
