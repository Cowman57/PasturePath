import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/services/geometry.dart';

/// Splitting an edge next to a grabbed vertex. The side must be explicit: with
/// the crosshair sitting on the vertex itself, both adjacent edges are zero
/// distance away, so a "nearest edge" test has no unique answer.
void main() {
  // Square, counter-clockwise starting bottom-left.
  const ring = [
    LatLng(0, 0),
    LatLng(0, 1),
    LatLng(1, 1),
    LatLng(1, 0),
  ];

  test('before inserts the midpoint of the previous edge', () {
    final out = insertMidpointAdjacentTo(ring, 0, before: true);

    expect(out.length, ring.length + 1);
    // Previous vertex of index 0 is the last one: (1,0).
    expect(out.first, const LatLng(0.5, 0));
    // The anchor and its neighbour survive either side of the new point.
    expect(out[1], const LatLng(0, 0));
    expect(out.last, const LatLng(1, 0));
  });

  test('after inserts the midpoint of the next edge', () {
    final out = insertMidpointAdjacentTo(ring, 2, before: false);

    expect(out.length, ring.length + 1);
    // Index 2 is (1,1); next is (1,0) → midpoint (1, 0.5) at index 3.
    expect(out[3], const LatLng(1, 0.5));
    expect(out[2], const LatLng(1, 1));
    expect(out[4], const LatLng(1, 0));
  });

  test('the input ring is left untouched', () {
    insertMidpointAdjacentTo(ring, 1, before: true);
    expect(ring.length, 4);
  });

  test('out of range indices are a no-op', () {
    expect(insertMidpointAdjacentTo(ring, -1, before: true), ring);
    expect(insertMidpointAdjacentTo(ring, 9, before: false), ring);
    expect(insertMidpointAdjacentTo(const [LatLng(0, 0)], 0, before: true).length, 1);
  });

  test('an explicit point lands on the requested side', () {
    // The "+" handles sit a fixed screen distance from the grabbed vertex, not
    // at the edge midpoint, so the point must land exactly where it was tapped.
    const at = LatLng(0.25, 0.25);

    final after = insertVertexAdjacentTo(ring, 0, before: false, point: at);
    expect(after.length, ring.length + 1);
    expect(after[1], at);

    final before = insertVertexAdjacentTo(ring, 0, before: true, point: at);
    expect(before.length, ring.length + 1);
    expect(before[0], at);
  });
}
