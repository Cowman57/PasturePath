import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/models/job.dart';

void main() {
  group('SavedJob avgWorkingSpeedKph', () {
    test('JSON round-trip keeps a set working speed', () {
      final job = SavedJob(
        id: '01/08/26 Job 1',
        startedAt: DateTime(2026, 8, 1, 9),
        endedAt: DateTime(2026, 8, 1, 10),
        path: const [LatLng(-37, 175), LatLng(-37.001, 175)],
        paddockNames: const ['North'],
        totalHa: 5,
        avgSpeedKph: 6.0,
        avgWorkingSpeedKph: 9.5,
        pathDistanceM: 300,
        swathWidthM: 12,
        hasSavedSwathWidth: true,
      );

      final json = job.toJson();
      expect(json['avgWorkingSpeedKph'], 9.5);

      final again = SavedJob.fromJson(json);
      expect(again.avgWorkingSpeedKph, closeTo(9.5, 1e-9));
      expect(again.avgSpeedKph, closeTo(6.0, 1e-9));
      // copyWith must carry the value through untouched.
      expect(again.copyWith().avgWorkingSpeedKph, closeTo(9.5, 1e-9));
    });

    test('JSON omits working speed when null', () {
      final job = SavedJob(
        id: '01/08/26 Job 2',
        startedAt: DateTime(2026, 8, 1, 9),
        endedAt: DateTime(2026, 8, 1, 10),
        path: const [LatLng(-37, 175), LatLng(-37.001, 175)],
        paddockNames: const ['North'],
        totalHa: 5,
        avgSpeedKph: 6.0,
        pathDistanceM: 300,
        swathWidthM: 12,
        hasSavedSwathWidth: true,
      );

      expect(job.toJson().containsKey('avgWorkingSpeedKph'), isFalse);
      expect(SavedJob.fromJson(job.toJson()).avgWorkingSpeedKph, isNull);
    });

    test('legacy JSON without the field loads with null', () {
      final legacy = <String, dynamic>{
        'id': '01/08/26 Job 3',
        'startedAt': DateTime(2026, 8, 1, 9).toIso8601String(),
        'endedAt': DateTime(2026, 8, 1, 10).toIso8601String(),
        'path': [
          {'lat': -37.0, 'lng': 175.0},
          {'lat': -37.001, 'lng': 175.0},
        ],
        'paddockNames': ['North'],
        'totalHa': 5.0,
        'avgSpeedKph': 6.0,
        'pathDistanceM': 300.0,
        'swathWidthM': 12.0,
        'hasSavedSwathWidth': true,
      };

      expect(SavedJob.fromJson(legacy).avgWorkingSpeedKph, isNull);
    });
  });

  group('JobFileSummary avgWorkingSpeedKph', () {
    test('survives the summary JSON round-trip and passes through', () {
      final job = SavedJob(
        id: '01/08/26 Job 4',
        startedAt: DateTime(2026, 8, 1, 9),
        endedAt: DateTime(2026, 8, 1, 10),
        path: const [LatLng(-37, 175), LatLng(-37.001, 175)],
        paddockNames: const ['North'],
        totalHa: 5,
        avgSpeedKph: 6.0,
        avgWorkingSpeedKph: 11.25,
        pathDistanceM: 300,
        swathWidthM: 12,
        hasSavedSwathWidth: true,
      );

      final summary = JobFileSummary.fromSavedJob(job, '/tmp/job.json');
      expect(summary.avgWorkingSpeedKph, closeTo(11.25, 1e-9));
      final json = summary.toJson();
      expect(json['avgWorkingSpeedKph'], 11.25);
      expect(
        JobFileSummary.fromJson('/tmp/job.json', json).avgWorkingSpeedKph,
        closeTo(11.25, 1e-9),
      );
    });
  });
}
