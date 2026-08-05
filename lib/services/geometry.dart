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

LatLng _lerpLatLng(LatLng a, LatLng b, double t) {
  return LatLng(
    a.latitude + (b.latitude - a.latitude) * t,
    a.longitude + (b.longitude - a.longitude) * t,
  );
}

/// Best interior point for a label — grid search for max distance from boundary.
LatLng bestInteriorLabelPoint(List<LatLng> outer, List<List<LatLng>> holes) {
  if (outer.isEmpty) return const LatLng(0, 0);

  double minLat = outer.first.latitude, maxLat = minLat;
  double minLng = outer.first.longitude, maxLng = minLng;
  for (final p in outer) {
    minLat = math.min(minLat, p.latitude);
    maxLat = math.max(maxLat, p.latitude);
    minLng = math.min(minLng, p.longitude);
    maxLng = math.max(maxLng, p.longitude);
  }

  const grid = 28;
  LatLng? best;
  double bestScore = -1;

  for (int i = 0; i <= grid; i++) {
    for (int j = 0; j <= grid; j++) {
      final lat = minLat + (maxLat - minLat) * i / grid;
      final lng = minLng + (maxLng - minLng) * j / grid;
      final p = LatLng(lat, lng);
      if (!pointInPolygon(p, outer, holes)) continue;
      final score = _minDistToBoundaryMeters(p, outer, holes);
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
  }
  if (best != null) return best;

  // Shoelace centroid fallback
  final c = _shoelaceCentroid(outer);
  if (pointInPolygon(c, outer, holes)) return c;

  // Midpoint of longest edge
  double bestLen = -1;
  LatLng bestMid = outer.first;
  for (int i = 0; i < outer.length; i++) {
    final a = outer[i], b = outer[(i + 1) % outer.length];
    final d = _distMeters(a, b);
    if (d > bestLen) {
      bestLen = d;
      bestMid = LatLng((a.latitude + b.latitude) * 0.5, (a.longitude + b.longitude) * 0.5);
    }
  }
  if (pointInPolygon(bestMid, outer, holes)) return bestMid;

  return outer.first;
}

LatLng _shoelaceCentroid(List<LatLng> ring) {
  double a = 0, cx = 0, cy = 0;
  for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude;
    final xj = ring[j].longitude, yj = ring[j].latitude;
    final f = xi * yj - xj * yi;
    a += f;
    cx += (xi + xj) * f;
    cy += (yi + yj) * f;
  }
  if (a.abs() < 1e-12) return ring.first;
  a *= 0.5;
  return LatLng(cy / (6 * a), cx / (6 * a));
}

double _minDistToBoundaryMeters(LatLng p, List<LatLng> outer, List<List<LatLng>> holes) {
  double best = double.infinity;
  void walkRing(List<LatLng> ring) {
    for (int i = 0; i < ring.length; i++) {
      final a = ring[i], b = ring[(i + 1) % ring.length];
      best = math.min(best, _distPointToSegMeters(p, a, b));
    }
  }
  walkRing(outer);
  for (final h in holes) walkRing(h);
  return best;
}

double _distMeters(LatLng a, LatLng b) {
  const Rm = 111320.0;
  final lat0 = ((a.latitude + b.latitude) * 0.5) * math.pi / 180.0;
  final dE = (b.longitude - a.longitude) * Rm * math.cos(lat0);
  final dN = (b.latitude - a.latitude) * Rm;
  return math.sqrt(dE * dE + dN * dN);
}

/// Total path length in meters.
double pathDistanceMeters(List<LatLng> path) {
  if (path.length < 2) return 0;
  double total = 0;
  for (int i = 1; i < path.length; i++) {
    total += _distMeters(path[i - 1], path[i]);
  }
  return total;
}

/// Prefer stored applied metres, but fall back to path geometry when stored
/// length is clearly inflated (legacy boom zig-zag / dual-fix counting).
///
/// New jobs store paddock-gated simplified path length, which should already
/// match geometry; this mainly corrects older inflated files.
double sanitizeAppliedPathDistanceM(double storedM, List<LatLng> path) {
  final geom = pathDistanceMeters(path);
  if (storedM <= 0) return geom;
  if (geom <= 0) return storedM;
  if (storedM > geom * 1.15) return geom;
  return storedM;
}

/// Area applied in hectares (path length × swath width).
double areaAppliedHa(List<LatLng> path, double swathWidthM) {
  return pathDistanceMeters(path) * swathWidthM / 10000.0;
}

/// Coverage percentage capped at 100.
double coveragePercent(List<LatLng> path, double swathWidthM, double paddockAreaHa) {
  if (paddockAreaHa <= 0) return 0;
  final applied = areaAppliedHa(path, swathWidthM);
  return (applied / paddockAreaHa * 100).clamp(0, double.infinity);
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

/// Parametric t on segment AB where it intersects CD, or null.
double? _segmentIntersectionT(LatLng a, LatLng b, LatLng c, LatLng d) {
  const Rm = 111320.0;
  final lat0 = ((a.latitude + b.latitude + c.latitude + d.latitude) * 0.25) * math.pi / 180.0;
  final cosLat = math.cos(lat0);

  double toX(LatLng p) => p.longitude * Rm * cosLat;
  double toY(LatLng p) => p.latitude * Rm;

  final ax = toX(a), ay = toY(a);
  final bx = toX(b), by = toY(b);
  final cx = toX(c), cy = toY(c);
  final dx = toX(d), dy = toY(d);

  final rX = bx - ax, rY = by - ay;
  final sX = dx - cx, sY = dy - cy;
  final denom = rX * sY - rY * sX;
  if (denom.abs() < 1e-9) return null;

  final qpx = cx - ax, qpy = cy - ay;
  final t = (qpx * sY - qpy * sX) / denom;
  final u = (qpx * rY - qpy * rX) / denom;
  if (t < -1e-9 || t > 1 + 1e-9 || u < -1e-9 || u > 1 + 1e-9) return null;
  return t.clamp(0.0, 1.0);
}

List<double> _collectClipTs(
  LatLng a,
  LatLng b,
  List<LatLng> outer,
  List<List<LatLng>> holes,
) {
  final ts = <double>[0.0, 1.0];
  void addRing(List<LatLng> ring) {
    if (ring.length < 2) return;
    for (int i = 0; i < ring.length; i++) {
      final j = (i + 1) % ring.length;
      final t = _segmentIntersectionT(a, b, ring[i], ring[j]);
      if (t != null && t > 1e-10 && t < 1.0 - 1e-10) ts.add(t);
    }
  }
  addRing(outer);
  for (final h in holes) addRing(h);
  ts.sort();
  // Deduplicate near-equal t values
  final out = <double>[];
  for (final t in ts) {
    if (out.isEmpty || (t - out.last).abs() > 1e-9) out.add(t);
  }
  return out;
}

/// Clip a long AB line to a polygon with holes using exact edge intersections.
List<List<LatLng>> clipLineABToPolygonExact(
  LatLng a,
  LatLng b,
  List<LatLng> outer,
  List<List<LatLng>> holes,
) {
  if (outer.length < 3) return [];
  final ts = _collectClipTs(a, b, outer, holes);
  final segments = <List<LatLng>>[];

  for (int i = 0; i < ts.length - 1; i++) {
    final t0 = ts[i], t1 = ts[i + 1];
    if (t1 - t0 < 1e-12) continue;
    final mid = _lerpLatLng(a, b, (t0 + t1) * 0.5);
    if (pointInPolygon(mid, outer, holes)) {
      segments.add([_lerpLatLng(a, b, t0), _lerpLatLng(a, b, t1)]);
    }
  }
  return segments;
}

/// Max |perpendicular| distance (metres) from [origin] along unit normal (east, north).
double guidancePerpendicularExtentM({
  required LatLng origin,
  required double normalEast,
  required double normalNorth,
  required Iterable<List<LatLng>> outerRings,
}) {
  const rm = 111320.0;
  final cosLat = math.cos(origin.latitude * math.pi / 180.0);
  var maxAbs = 0.0;
  for (final ring in outerRings) {
    for (final p in ring) {
      final east = (p.longitude - origin.longitude) * rm * cosLat;
      final north = (p.latitude - origin.latitude) * rm;
      final perp = east * normalEast + north * normalNorth;
      maxAbs = math.max(maxAbs, perp.abs());
    }
  }
  return maxAbs;
}

/// Max |along-track| distance (metres) from [origin] along unit tangent (east, north).
double guidanceAlongTrackExtentM({
  required LatLng origin,
  required double tangentEast,
  required double tangentNorth,
  required Iterable<List<LatLng>> outerRings,
}) {
  const rm = 111320.0;
  final cosLat = math.cos(origin.latitude * math.pi / 180.0);
  var maxAbs = 0.0;
  for (final ring in outerRings) {
    for (final p in ring) {
      final east = (p.longitude - origin.longitude) * rm * cosLat;
      final north = (p.latitude - origin.latitude) * rm;
      final along = east * tangentEast + north * tangentNorth;
      maxAbs = math.max(maxAbs, along.abs());
    }
  }
  return maxAbs;
}

/// Parallel guidance span from paddock width with safety margin and cap.
double guidanceParallelSpanM({
  required double perpendicularExtentM,
  double safetyFactor = 2.0,
  double capM = 500.0,
  double minSpanM = 0.0,
}) {
  final span = perpendicularExtentM * safetyFactor;
  return span.clamp(minSpanM, capM);
}

class _XY {
  final double x;
  final double y;
  const _XY(this.x, this.y);

  double get length => math.sqrt(x * x + y * y);

  _XY operator +(_XY o) => _XY(x + o.x, y + o.y);
  _XY operator -(_XY o) => _XY(x - o.x, y - o.y);
  _XY operator *(double s) => _XY(x * s, y * s);

  _XY normalized() {
    final len = length;
    if (len < 1e-12) return const _XY(0, 0);
    return _XY(x / len, y / len);
  }

  _XY perpLeft() => _XY(-y, x);
  _XY perpRight() => _XY(y, -x);

  double dot(_XY o) => x * o.x + y * o.y;
}

_XY _toLocal(LatLng p, LatLng origin, double cosLat) {
  return _XY(
    (p.longitude - origin.longitude) * 111320.0 * cosLat,
    (p.latitude - origin.latitude) * 111320.0,
  );
}

LatLng _fromLocal(_XY v, LatLng origin, double cosLat) {
  return LatLng(
    origin.latitude + v.y / 111320.0,
    origin.longitude + v.x / (111320.0 * cosLat),
  );
}

/// Offset a point perpendicular to [dir] (local metres).
_XY _offsetAlong(_XY pt, _XY dir, double offset, {required bool left}) {
  if (dir.length < 1e-9) return pt;
  final n = left ? dir.normalized().perpLeft() : dir.normalized().perpRight();
  return pt + n * offset;
}

/// Drop micro-movement wiggles that cause self-intersecting swath geometry.
List<LatLng> simplifySwathPath(List<LatLng> path, {double minDistM = 0.55}) {
  if (path.length < 3) return List<LatLng>.from(path);

  final out = <LatLng>[path.first];
  for (int i = 1; i < path.length - 1; i++) {
    final prev = out.last;
    final curr = path[i];
    final next = path[i + 1];
    if (_distMeters(prev, curr) < minDistM) continue;

    final bearingIn = math.atan2(
      curr.longitude - prev.longitude,
      curr.latitude - prev.latitude,
    );
    final bearingOut = math.atan2(
      next.longitude - curr.longitude,
      next.latitude - curr.latitude,
    );
    var turnDeg = (bearingOut - bearingIn) * 180.0 / math.pi;
    while (turnDeg > 180) turnDeg -= 360;
    while (turnDeg < -180) turnDeg += 360;

    // Skip tight GPS back-and-forth on short hops.
    if (turnDeg.abs() > 28 && _distMeters(prev, curr) < 3.0) continue;

    out.add(curr);
  }

  final last = path.last;
  if (out.isEmpty || _distMeters(out.last, last) >= minDistM * 0.5) {
    out.add(last);
  }
  return out;
}

double _bearingDeg(LatLng from, LatLng to) {
  return const Distance().bearing(from, to);
}

double _normalizeAngleDeg(double deg) {
  var d = deg % 360;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
}

double _angleDiffDeg(double fromDeg, double toDeg) =>
    _normalizeAngleDeg(toDeg - fromDeg);

/// True when [candidate] steps backward relative to travel prev→anchor.
bool isBackwardGpsStep(
  LatLng anchor,
  LatLng prev,
  LatLng candidate, {
  double maxReverseDeg = 95,
  double minSegM = 0.12,
}) {
  final d = _distMeters(anchor, candidate);
  if (d < minSegM) return true;
  final travel = _bearingDeg(prev, anchor);
  final step = _bearingDeg(anchor, candidate);
  return _angleDiffDeg(travel, step).abs() > maxReverseDeg;
}

/// Drop short hops and GPS back-flicks that fold the swath corridor.
List<LatLng> filterForwardGpsPath(
  List<LatLng> path, {
  double minSegM = 0.5,
  double maxReverseDeg = 95,
}) {
  if (path.isEmpty) return [];
  final out = <LatLng>[path.first];
  for (int i = 1; i < path.length; i++) {
    final curr = path[i];
    final prev = out.last;
    final d = _distMeters(prev, curr);
    if (d < minSegM) continue;
    if (out.length >= 2 &&
        isBackwardGpsStep(
          prev,
          out[out.length - 2],
          curr,
          maxReverseDeg: maxReverseDeg,
        )) {
      continue;
    }
    out.add(curr);
  }
  return out;
}

/// Break a path where the tractor backtracks (separate swath ribbons).
List<List<LatLng>> splitPathAtReversals(
  List<LatLng> path, {
  double maxReverseDeg = 95,
}) {
  if (path.length < 2) return path.isEmpty ? [] : [List<LatLng>.from(path)];

  final segments = <List<LatLng>>[];
  var seg = <LatLng>[path.first];

  for (int i = 1; i < path.length; i++) {
    final curr = path[i];
    if (seg.length >= 2 &&
        isBackwardGpsStep(
          seg.last,
          seg[seg.length - 2],
          curr,
          maxReverseDeg: maxReverseDeg,
        )) {
      if (seg.length >= 2) segments.add(List<LatLng>.from(seg));
      seg = [curr];
    } else {
      if (seg.isEmpty || _distMeters(seg.last, curr) >= 0.05) {
        seg.add(curr);
      }
    }
  }
  if (seg.length >= 2) segments.add(seg);
  return segments;
}

/// Offset [point] behind/right relative to travel [bearingDeg] (metres).
LatLng offsetFromTravel(
  LatLng point,
  double bearingDeg,
  double behindM,
  double rightM,
) {
  const rm = 111320.0;
  final rad = bearingDeg * math.pi / 180.0;
  final fNorth = math.cos(rad);
  final fEast = math.sin(rad);
  final northM = -fNorth * behindM - fEast * rightM;
  final eastM = -fEast * behindM + fNorth * rightM;
  final cosLat = math.cos(point.latitude * math.pi / 180.0);
  return LatLng(
    point.latitude + northM / rm,
    point.longitude + eastM / (rm * cosLat),
  );
}

/// Boom-centre path from GPS fixes using path-tangent travel direction (stable corners).
List<LatLng> implementCenterPathFromGps(
  List<LatLng> gpsPath, {
  required double gpsBehindM,
  required double gpsLateralM,
  required double hitchToAxleM,
  required double boomLateralM,
}) {
  if (gpsPath.isEmpty) return [];
  final behindM = gpsBehindM + hitchToAxleM;
  final lateralM = gpsLateralM + boomLateralM;

  if (gpsPath.length == 1) {
    return [gpsPath.first];
  }

  final out = <LatLng>[];
  for (int i = 0; i < gpsPath.length; i++) {
    late double bearing;
    if (i == 0) {
      bearing = _bearingDeg(gpsPath[0], gpsPath[1]);
    } else if (i == gpsPath.length - 1) {
      bearing = _bearingDeg(gpsPath[i - 1], gpsPath[i]);
    } else {
      bearing = _bearingDeg(gpsPath[i - 1], gpsPath[i + 1]);
    }
    out.add(offsetFromTravel(gpsPath[i], bearing, behindM, lateralM));
  }
  return out;
}

/// One boom pose: centre point and geographic heading (0 = north).
class SwathStamp {
  final LatLng center;
  final double headingDeg;

  const SwathStamp(this.center, this.headingDeg);
}

List<SwathStamp> simplifySwathStamps(
  List<SwathStamp> stamps, {
  double minDistM = 0.4,
}) {
  if (stamps.length < 3) return List<SwathStamp>.from(stamps);

  final out = <SwathStamp>[stamps.first];
  for (int i = 1; i < stamps.length - 1; i++) {
    final prev = out.last;
    final curr = stamps[i];
    if (_distMeters(prev.center, curr.center) < minDistM) continue;
    out.add(curr);
  }

  final last = stamps.last;
  if (out.isEmpty || _distMeters(out.last.center, last.center) >= minDistM * 0.5) {
    out.add(last);
  }
  return out;
}

/// Total path length (metres) along stamp centres.
double pathDistanceMFromStamps(List<SwathStamp> stamps) {
  if (stamps.length < 2) return 0;
  var total = 0.0;
  for (int i = 1; i < stamps.length; i++) {
    total += _distMeters(stamps[i - 1].center, stamps[i].center);
  }
  return total;
}

/// Swath corridor from oriented boom stamps (paint-brush model).
/// Uses bevel joins along the centre path so sharp corners stay filled.
List<LatLng> buildSwathRingFromOrientedStamps(
  List<SwathStamp> stamps,
  double widthM,
) {
  if (stamps.length < 2) return [];
  final path = stamps.map((s) => s.center).toList();
  return buildSwathRingFromPath(path, widthM);
}

List<List<SwathStamp>> splitStampsAtJumps(
  List<SwathStamp> stamps, {
  double maxJumpM = 40,
}) {
  if (stamps.isEmpty) return [];
  final segments = <List<SwathStamp>>[];
  var seg = <SwathStamp>[stamps.first];

  for (int i = 1; i < stamps.length; i++) {
    final d = _distMeters(stamps[i - 1].center, stamps[i].center);
    if (d > maxJumpM) {
      if (seg.length >= 2) segments.add(seg);
      seg = [stamps[i]];
    } else {
      seg.add(stamps[i]);
    }
  }
  if (seg.length >= 2) segments.add(seg);
  return segments;
}

List<List<LatLng>> buildSwathRingsFromOrientedStamps(
  List<SwathStamp> stamps,
  double widthM,
) {
  final rings = <List<LatLng>>[];
  for (final seg in splitStampsAtJumps(stamps)) {
    final simplified = simplifySwathStamps(seg);
    if (simplified.length < 2) continue;
    final ring = buildSwathRingFromOrientedStamps(simplified, widthM);
    if (ring.length >= 3) rings.add(ring);
  }
  return rings;
}

/// Closed ring for a swath corridor along [path] with bevel joins (no miter spikes).
List<LatLng> buildSwathRingFromPath(List<LatLng> path, double widthM) {
  if (path.length < 2) return [];

  final half = (widthM <= 0 ? 3.0 : widthM) * 0.5;
  final origin = path[path.length ~/ 2];
  final cosLat = math.cos(origin.latitude * math.pi / 180.0);

  final left = <_XY>[];
  final right = <_XY>[];

  for (int i = 0; i < path.length; i++) {
    final curr = _toLocal(path[i], origin, cosLat);
    late _XY inDir;
    late _XY outDir;

    if (i == 0) {
      final next = _toLocal(path[1], origin, cosLat);
      inDir = next - curr;
      outDir = inDir;
      if (outDir.length < 1e-9) continue;
      left.add(_offsetAlong(curr, outDir, half, left: true));
      right.add(_offsetAlong(curr, outDir, half, left: false));
    } else if (i == path.length - 1) {
      final prev = _toLocal(path[i - 1], origin, cosLat);
      inDir = curr - prev;
      outDir = inDir;
      if (inDir.length < 1e-9) continue;
      left.add(_offsetAlong(curr, inDir, half, left: true));
      right.add(_offsetAlong(curr, inDir, half, left: false));
    } else {
      final prev = _toLocal(path[i - 1], origin, cosLat);
      final next = _toLocal(path[i + 1], origin, cosLat);
      inDir = curr - prev;
      outDir = next - curr;
      if (inDir.length < 1e-9 || outDir.length < 1e-9) continue;
      // Bevel: two corners per side — avoids miter self-intersection on sharp turns.
      left
        ..add(_offsetAlong(curr, inDir, half, left: true))
        ..add(_offsetAlong(curr, outDir, half, left: true));
      right
        ..add(_offsetAlong(curr, inDir, half, left: false))
        ..add(_offsetAlong(curr, outDir, half, left: false));
    }
  }

  if (left.length < 2 || right.length < 2) return [];

  final ring = <LatLng>[
    for (final v in left) _fromLocal(v, origin, cosLat),
    for (final v in right.reversed) _fromLocal(v, origin, cosLat),
  ];
  return ring;
}

/// Split a GPS path at large jumps (pause / glitch).
List<List<LatLng>> splitPathAtJumps(List<LatLng> path, {double maxJumpM = 40}) {
  if (path.isEmpty) return [];
  final segments = <List<LatLng>>[];
  var seg = <LatLng>[path.first];

  for (int i = 1; i < path.length; i++) {
    final d = _distMeters(path[i - 1], path[i]);
    if (d > maxJumpM) {
      if (seg.length >= 2) segments.add(seg);
      seg = [path[i]];
    } else {
      seg.add(path[i]);
    }
  }
  if (seg.length >= 2) segments.add(seg);
  return segments;
}

/// One closed ring per continuous forward path segment.
List<List<LatLng>> buildSwathRingsFromPath(List<LatLng> path, double widthM) {
  final rings = <List<LatLng>>[];
  final forward = filterForwardGpsPath(path);
  for (final jumpSeg in splitPathAtJumps(forward)) {
    for (final seg in splitPathAtReversals(jumpSeg)) {
      final simplified = simplifySwathPath(seg);
      if (simplified.length < 2) continue;
      final ring = buildSwathRingFromPath(simplified, widthM);
      if (ring.length >= 3) rings.add(ring);
    }
  }
  return rings;
}
class _OverlapCell {
  int lastSegIdx = -1000000;
  int overlapCount = 0;
}

double _distPointToSegXY(_XY p, _XY a, _XY b) {
  final vx = b.x - a.x, vy = b.y - a.y;
  final wx = p.x - a.x, wy = p.y - a.y;
  final c1 = vx * wx + vy * wy;
  if (c1 <= 0) return (p - a).length;
  final c2 = vx * vx + vy * vy;
  if (c2 <= c1) return (p - b).length;
  final t = c1 / c2;
  return (p - _XY(a.x + t * vx, a.y + t * vy)).length;
}

void _stampSegmentOverlap(
  _XY a,
  _XY b,
  int segIdx,
  double halfW,
  double cellM,
  Map<String, _OverlapCell> cells,
  int minGap,
) {
  final minX = math.min(a.x, b.x) - halfW;
  final maxX = math.max(a.x, b.x) + halfW;
  final minY = math.min(a.y, b.y) - halfW;
  final maxY = math.max(a.y, b.y) + halfW;

  final minGx = (minX / cellM).floor();
  final maxGx = (maxX / cellM).floor();
  final minGy = (minY / cellM).floor();
  final maxGy = (maxY / cellM).floor();

  for (int gx = minGx; gx <= maxGx; gx++) {
    for (int gy = minGy; gy <= maxGy; gy++) {
      final cx = (gx + 0.5) * cellM;
      final cy = (gy + 0.5) * cellM;
      if (_distPointToSegXY(_XY(cx, cy), a, b) > halfW) continue;

      final key = '$gx,$gy';
      final cell = cells.putIfAbsent(key, () => _OverlapCell());
      if (segIdx - cell.lastSegIdx >= minGap) {
        cell.overlapCount++;
      }
      cell.lastSegIdx = segIdx;
    }
  }
}

List<LatLng> _cellRectRing(
  int gx0,
  int gx1,
  int gy,
  LatLng origin,
  double cosLat,
  double cellM,
) {
  final x0 = gx0 * cellM;
  final x1 = (gx1 + 1) * cellM;
  final y0 = gy * cellM;
  final y1 = (gy + 1) * cellM;
  return [
    _fromLocal(_XY(x0, y0), origin, cosLat),
    _fromLocal(_XY(x1, y0), origin, cosLat),
    _fromLocal(_XY(x1, y1), origin, cosLat),
    _fromLocal(_XY(x0, y1), origin, cosLat),
  ];
}

List<List<LatLng>> _mergedCellRings(
  List<String> cellKeys,
  LatLng origin,
  double cosLat,
  double cellM,
) {
  final byRow = <int, Set<int>>{};
  for (final key in cellKeys) {
    final comma = key.indexOf(',');
    if (comma < 0) continue;
    final gx = int.tryParse(key.substring(0, comma));
    final gy = int.tryParse(key.substring(comma + 1));
    if (gx == null || gy == null) continue;
    byRow.putIfAbsent(gy, () => <int>{}).add(gx);
  }

  final rings = <List<LatLng>>[];
  for (final gy in byRow.keys) {
    final cols = byRow[gy]!.toList()..sort();
    var runStart = cols.first;
    var runEnd = cols.first;
    for (int i = 1; i < cols.length; i++) {
      if (cols[i] == runEnd + 1) {
        runEnd = cols[i];
      } else {
        rings.add(_cellRectRing(runStart, runEnd, gy, origin, cosLat, cellM));
        runStart = runEnd = cols[i];
      }
    }
    rings.add(_cellRectRing(runStart, runEnd, gy, origin, cosLat, cellM));
  }
  return rings;
}

/// Regions where separate passes overlap, grouped by overlap depth (1 = double coverage).
Map<int, List<List<LatLng>>> buildSwathOverlapRingsByCount(
  List<LatLng> path,
  double widthM, {
  double maxJumpM = 40,
  double minSegmentM = 0.35,
}) {
  if (path.length < 2) return {};

  final wM = widthM <= 0 ? 3.0 : widthM;
  final half = wM * 0.5;
  final cellM = (wM / 3.0).clamp(0.5, 1.25);
  final minGap = math.max(8, (wM / minSegmentM * 1.25).ceil());

  final origin = path[path.length ~/ 2];
  final cosLat = math.cos(origin.latitude * math.pi / 180.0);
  final cells = <String, _OverlapCell>{};
  var segIdx = 0;

  for (final sub in splitPathAtJumps(path, maxJumpM: maxJumpM)) {
    for (int i = 1; i < sub.length; i++) {
      final a = sub[i - 1];
      final b = sub[i];
      if (_distMeters(a, b) < minSegmentM) continue;

      _stampSegmentOverlap(
        _toLocal(a, origin, cosLat),
        _toLocal(b, origin, cosLat),
        segIdx,
        half,
        cellM,
        cells,
        minGap,
      );
      segIdx++;
    }
  }

  final byCount = <int, List<String>>{};
  for (final e in cells.entries) {
    if (e.value.overlapCount < 1) continue;
    byCount.putIfAbsent(e.value.overlapCount, () => []).add(e.key);
  }

  final result = <int, List<List<LatLng>>>{};
  for (final e in byCount.entries) {
    result[e.key] = _mergedCellRings(e.value, origin, cosLat, cellM);
  }
  return result;
}

/// Offset a polyline parallel to itself. Positive [offsetM] = left of travel direction.
List<LatLng> parallelOffsetPath(List<LatLng> path, double offsetM) {
  if (path.length < 2 || offsetM.abs() < 1e-9) return List<LatLng>.from(path);

  final dist = offsetM.abs();
  final leftSide = offsetM > 0;
  final origin = path[path.length ~/ 2];
  final cosLat = math.cos(origin.latitude * math.pi / 180.0);
  final out = <LatLng>[];

  for (int i = 0; i < path.length; i++) {
    final curr = _toLocal(path[i], origin, cosLat);
    late _XY inDir;
    late _XY outDir;

    if (i == 0) {
      final next = _toLocal(path[1], origin, cosLat);
      inDir = next - curr;
      outDir = inDir;
    } else if (i == path.length - 1) {
      final prev = _toLocal(path[i - 1], origin, cosLat);
      inDir = curr - prev;
      outDir = inDir;
    } else {
      final prev = _toLocal(path[i - 1], origin, cosLat);
      final next = _toLocal(path[i + 1], origin, cosLat);
      inDir = curr - prev;
      outDir = next - curr;
    }

    if (inDir.length < 1e-9 || outDir.length < 1e-9) {
      out.add(path[i]);
      continue;
    }

    final _XY off;
    if (i == 0) {
      off = _offsetAlong(curr, outDir, dist, left: leftSide);
    } else if (i == path.length - 1) {
      off = _offsetAlong(curr, inDir, dist, left: leftSide);
    } else {
      final a = _offsetAlong(curr, inDir, dist, left: leftSide);
      final b = _offsetAlong(curr, outDir, dist, left: leftSide);
      off = _XY((a.x + b.x) * 0.5, (a.y + b.y) * 0.5);
    }
    out.add(_fromLocal(off, origin, cosLat));
  }
  return out;
}

/// Clip each segment of [line] to a polygon with holes.
List<List<LatLng>> clipPolylineToPolygon(
  List<LatLng> line,
  List<LatLng> outer,
  List<List<LatLng>> holes,
) {
  if (line.length < 2) return [];
  final parts = <List<LatLng>>[];
  for (int i = 0; i < line.length - 1; i++) {
    for (final seg in clipLineABToPolygonExact(line[i], line[i + 1], outer, holes)) {
      if (seg.length >= 2) parts.add(seg);
    }
  }
  return parts;
}

