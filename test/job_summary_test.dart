import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/models/job.dart';

void main() {
  group('JobFileSummary coverage', () {
    test('coverage uses pathDistanceM x width / paddock ha', () {
      final summary = JobFileSummary(
        filePath: '/tmp/job.json',
        id: 'Job 1',
        startedAt: DateTime(2026, 8, 1),
        endedAt: DateTime(2026, 8, 1, 1),
        paddockNames: const ['A'],
        totalHa: 10.0,
        avgSpeedKph: 8.0,
        pathDistanceM: 5000.0, // 5 km
        swathWidthM: 20.0, // 20 m → 10 ha applied
        hasSavedSwathWidth: true,
      );
      expect(summary.areaAppliedHaFor(20), closeTo(10.0, 0.01));
      expect(summary.coveragePercentFor(20), closeTo(100.0, 0.1));
    });

    test('coverage can exceed 100% when overlaps inflate path length', () {
      final summary = JobFileSummary(
        filePath: '/tmp/job.json',
        id: 'Job 2',
        startedAt: DateTime(2026, 8, 1),
        endedAt: DateTime(2026, 8, 1, 1),
        paddockNames: const ['A'],
        totalHa: 10.0,
        avgSpeedKph: 8.0,
        pathDistanceM: 7500.0,
        swathWidthM: 20.0, // 15 ha applied → 150%
        hasSavedSwathWidth: true,
      );
      expect(summary.coveragePercentFor(20), closeTo(150.0, 0.1));
    });
  });

  group('SavedJob', () {
    test('fromJson round-trips pathDistanceM', () {
      final job = SavedJob(
        id: '01/08/26 Job 1',
        startedAt: DateTime(2026, 8, 1, 9),
        endedAt: DateTime(2026, 8, 1, 10),
        path: const [LatLng(-37, 175), LatLng(-37.001, 175)],
        paddockNames: const ['North'],
        totalHa: 5,
        avgSpeedKph: 7,
        pathDistanceM: 321.5,
        swathWidthM: 12,
        hasSavedSwathWidth: true,
      );
      final again = SavedJob.fromJson(job.toJson());
      expect(again.pathDistanceM, closeTo(321.5, 0.01));
      expect(again.path.length, 2);
    });
  });
}
