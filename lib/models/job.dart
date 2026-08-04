import 'package:latlong2/latlong.dart';
import '../services/geometry.dart';

/// Lightweight job record for history lists (no GPS path).
class JobFileSummary {
  final String filePath;
  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final List<String> paddockNames;
  final double totalHa;
  final double avgSpeedKph;
  final double? swathWidthM;
  final double pathDistanceM;
  final double? swathWidthSetting;
  final String? unitsAtSave;
  final bool hasSavedSwathWidth;

  const JobFileSummary({
    required this.filePath,
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.paddockNames,
    required this.totalHa,
    required this.avgSpeedKph,
    this.swathWidthM,
    this.pathDistanceM = 0,
    this.swathWidthSetting,
    this.unitsAtSave,
    this.hasSavedSwathWidth = false,
  });

  factory JobFileSummary.fromSavedJob(SavedJob job, String filePath) {
    return JobFileSummary(
      filePath: filePath,
      id: job.id,
      startedAt: job.startedAt,
      endedAt: job.endedAt,
      paddockNames: List<String>.from(job.paddockNames),
      totalHa: job.totalHa,
      avgSpeedKph: job.avgSpeedKph,
      swathWidthM: job.swathWidthM,
      pathDistanceM: job.effectiveAppliedDistanceM,
      swathWidthSetting: job.swathWidthSetting,
      unitsAtSave: job.unitsAtSave,
      hasSavedSwathWidth: job.hasSavedSwathWidth,
    );
  }

  factory JobFileSummary.fromJson(String filePath, Map<String, dynamic> j) {
    final hasSaved = j['hasSavedSwathWidth'] == true ||
        j['swathWidthSetting'] != null;
    var pathDist = (j['pathDistanceM'] as num?)?.toDouble() ?? 0;
    final rawPath = j['path'];
    if (rawPath is List && rawPath.length >= 2) {
      final pts = <LatLng>[];
      for (final m in rawPath) {
        if (m is Map) {
          pts.add(LatLng(
            (m['lat'] as num).toDouble(),
            (m['lng'] as num).toDouble(),
          ));
        }
      }
      if (pts.length >= 2) {
        pathDist = sanitizeAppliedPathDistanceM(pathDist, pts);
      }
    }
    return JobFileSummary(
      filePath: filePath,
      id: j['id'] as String,
      startedAt: DateTime.parse(j['startedAt'] as String),
      endedAt: DateTime.parse(j['endedAt'] as String),
      paddockNames: (j['paddockNames'] as List).map((e) => e.toString()).toList(),
      totalHa: (j['totalHa'] as num).toDouble(),
      avgSpeedKph: (j['avgSpeedKph'] as num).toDouble(),
      swathWidthM: (j['swathWidthM'] as num?)?.toDouble(),
      pathDistanceM: pathDist,
      swathWidthSetting: (j['swathWidthSetting'] as num?)?.toDouble(),
      unitsAtSave: j['unitsAtSave'] as String?,
      hasSavedSwathWidth: hasSaved,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'paddockNames': paddockNames,
    'totalHa': totalHa,
    'avgSpeedKph': avgSpeedKph,
    'swathWidthM': swathWidthM,
    'pathDistanceM': pathDistanceM,
    'swathWidthSetting': swathWidthSetting,
    'unitsAtSave': unitsAtSave,
    'hasSavedSwathWidth': hasSavedSwathWidth,
  };

  double? get storedSwathWidthM {
    if (swathWidthM != null && swathWidthM! > 0) return swathWidthM;
    if (swathWidthSetting != null && swathWidthSetting! > 0) {
      return unitsAtSave == 'feet'
          ? swathWidthSetting! / 3.280839895
          : swathWidthSetting!;
    }
    return null;
  }

  double resolveSwathWidthM(double fallbackSwathWidthM) {
    if (hasSavedSwathWidth) {
      return storedSwathWidthM ?? fallbackSwathWidthM;
    }
    return fallbackSwathWidthM;
  }

  double areaAppliedHaFor(double fallbackSwathWidthM) =>
      pathDistanceM * resolveSwathWidthM(fallbackSwathWidthM) / 10000.0;

  double coveragePercentFor(double fallbackSwathWidthM) {
    if (totalHa <= 0) return 0;
    return (areaAppliedHaFor(fallbackSwathWidthM) / totalHa * 100)
        .clamp(0, double.infinity);
  }
}

class SavedJob {
  final String id;                 // "17/08/25 Job 1"
  final DateTime startedAt;
  final DateTime endedAt;
  final List<LatLng> path;         // recorded boom centre points
  final List<double>? pathHeadingsDeg; // boom heading per point (paint-brush swath)
  final List<String> paddockNames; // names saved for readability
  final double totalHa;
  final double avgSpeedKph;        // average speed across the job
  final double? swathWidthM;       // implement width in metres at job finish (null if not stored)
  final double pathDistanceM;      // applied path length (where swath was recorded)
  final double? swathWidthSetting; // width value in user units at job finish
  final String? unitsAtSave;       // 'meters' or 'feet' at job finish
  final bool hasSavedSwathWidth;   // true when width was persisted with the job

  SavedJob({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.path,
    this.pathHeadingsDeg,
    required this.paddockNames,
    required this.totalHa,
    required this.avgSpeedKph,
    this.swathWidthM,
    this.pathDistanceM = 0,
    this.swathWidthSetting,
    this.unitsAtSave,
    this.hasSavedSwathWidth = false,
  });

  double get effectiveAppliedDistanceM =>
      sanitizeAppliedPathDistanceM(pathDistanceM, path);

  /// Width in metres recorded with this job, if any.
  double? get storedSwathWidthM {
    if (swathWidthM != null && swathWidthM! > 0) return swathWidthM;
    if (swathWidthSetting != null && swathWidthSetting! > 0) {
      return unitsAtSave == 'feet'
          ? swathWidthSetting! / 3.280839895
          : swathWidthSetting!;
    }
    return null;
  }

  /// Uses saved job width when available, otherwise [fallbackSwathWidthM].
  double resolveSwathWidthM(double fallbackSwathWidthM) {
    if (hasSavedSwathWidth) {
      return storedSwathWidthM ?? fallbackSwathWidthM;
    }
    return fallbackSwathWidthM;
  }

  double areaAppliedHaFor(double fallbackSwathWidthM) =>
      effectiveAppliedDistanceM * resolveSwathWidthM(fallbackSwathWidthM) / 10000.0;

  double coveragePercentFor(double fallbackSwathWidthM) {
    if (totalHa <= 0) return 0;
    return (areaAppliedHaFor(fallbackSwathWidthM) / totalHa * 100).clamp(0, double.infinity);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'path': path.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList(),
    if (pathHeadingsDeg != null)
      'pathHeadings': pathHeadingsDeg,
    'paddockNames': paddockNames,
    'totalHa': totalHa,
    'avgSpeedKph': avgSpeedKph,
    'swathWidthM': swathWidthM,
    'pathDistanceM': pathDistanceM,
    'swathWidthSetting': swathWidthSetting,
    'unitsAtSave': unitsAtSave,
    'hasSavedSwathWidth': hasSavedSwathWidth,
  };

  static SavedJob fromJson(Map<String, dynamic> j) {
    final pts = <LatLng>[];
    for (final m in (j['path'] as List)) {
      pts.add(LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()));
    }

    final headings = <double>[];
    final rawHeadings = j['pathHeadings'];
    if (rawHeadings is List) {
      for (final v in rawHeadings) {
        if (v is num) headings.add(v.toDouble());
      }
    }
    final pathHeadings = headings.length == pts.length ? headings : null;

    final hasSaved = j['hasSavedSwathWidth'] == true ||
        j['swathWidthSetting'] != null;

    final pathDist = (j['pathDistanceM'] as num?)?.toDouble() ?? 0;

    return SavedJob(
      id: j['id'] as String,
      startedAt: DateTime.parse(j['startedAt']),
      endedAt: DateTime.parse(j['endedAt']),
      path: pts,
      pathHeadingsDeg: pathHeadings,
      paddockNames: (j['paddockNames'] as List).map((e) => e.toString()).toList(),
      totalHa: (j['totalHa'] as num).toDouble(),
      avgSpeedKph: (j['avgSpeedKph'] as num).toDouble(),
      swathWidthM: (j['swathWidthM'] as num?)?.toDouble(),
      pathDistanceM: pathDist,
      swathWidthSetting: (j['swathWidthSetting'] as num?)?.toDouble(),
      unitsAtSave: j['unitsAtSave'] as String?,
      hasSavedSwathWidth: hasSaved,
    );
  }
}
