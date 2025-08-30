import 'package:latlong2/latlong.dart';

class SavedJob {
  final String id;                 // "17/08/25 Job 1"
  final DateTime startedAt;
  final DateTime endedAt;
  final List<LatLng> path;         // recorded GPS points
  final List<String> paddockNames; // names saved for readability
  final double totalHa;
  final double avgSpeedKph;        // average speed across the job

  SavedJob({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.path,
    required this.paddockNames,
    required this.totalHa,
    required this.avgSpeedKph,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'path': path.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
    'paddockNames': paddockNames,
    'totalHa': totalHa,
    'avgSpeedKph': avgSpeedKph,
  };

  static SavedJob fromJson(Map<String, dynamic> j) {
    final pts = <LatLng>[];
    for (final m in (j['path'] as List)) {
      pts.add(LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()));
    }
    return SavedJob(
      id: j['id'] as String,
      startedAt: DateTime.parse(j['startedAt']),
      endedAt: DateTime.parse(j['endedAt']),
      path: pts,
      paddockNames: (j['paddockNames'] as List).map((e)=> e.toString()).toList(),
      totalHa: (j['totalHa'] as num).toDouble(),
      avgSpeedKph: (j['avgSpeedKph'] as num).toDouble(),
    );
  }
}
