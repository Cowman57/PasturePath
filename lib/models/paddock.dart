import 'package:latlong2/latlong.dart';

class Paddock {
  final String name;                 // e.g. "12"
  final List<LatLng> outer;          // outer ring (closed or open)
  final List<List<LatLng>> holes;    // zero or more holes
  final double areaHa;               // area in hectares
  final LatLng labelPoint;           // point inside polygon (not in holes)

  Paddock({
    required this.name,
    required this.outer,
    required this.holes,
    required this.areaHa,
    required this.labelPoint,
  });
}
