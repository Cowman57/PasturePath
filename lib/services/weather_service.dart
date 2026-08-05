import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/job_weather.dart';

/// Open-Meteo weather + rainfall context (no API key).
class WeatherService {
  static const _rainThresholdMm = 0.5;
  static const _lookbackDays = 45;
  static const _forecastDays = 16;

  static Future<JobWeather?> fetchForJob({
    required LatLng location,
    required DateTime at,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final day = DateTime(at.year, at.month, at.day);
      final startHist = day.subtract(const Duration(days: _lookbackDays));
      final lat = location.latitude.toStringAsFixed(4);
      final lng = location.longitude.toStringAsFixed(4);
      final startStr = _ymd(startHist);
      final endStr = _ymd(day);

      final archiveUri = Uri.parse(
        'https://archive-api.open-meteo.com/v1/archive'
        '?latitude=$lat&longitude=$lng'
        '&start_date=$startStr&end_date=$endStr'
        '&daily=precipitation_sum'
        '&timezone=auto',
      );
      final forecastUri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lng'
        '&daily=precipitation_sum'
        '&forecast_days=$_forecastDays'
        '&current=temperature_2m,precipitation,weather_code'
        '&timezone=auto',
      );

      final results = await Future.wait([
        http.get(archiveUri).timeout(timeout),
        http.get(forecastUri).timeout(timeout),
      ]);

      final archive = jsonDecode(results[0].body) as Map<String, dynamic>;
      final forecast = jsonDecode(results[1].body) as Map<String, dynamic>;

      final histDates = _stringList(archive['daily']?['time']);
      final histPrecip = _numList(archive['daily']?['precipitation_sum']);
      final futDates = _stringList(forecast['daily']?['time']);
      final futPrecip = _numList(forecast['daily']?['precipitation_sum']);

      int? daysSince;
      for (var i = histDates.length - 1; i >= 0; i--) {
        final d = DateTime.tryParse(histDates[i]);
        if (d == null) continue;
        final p = i < histPrecip.length ? histPrecip[i] : 0.0;
        if (p >= _rainThresholdMm) {
          daysSince = day.difference(DateTime(d.year, d.month, d.day)).inDays;
          break;
        }
      }

      int? daysUntil;
      for (var i = 0; i < futDates.length; i++) {
        final d = DateTime.tryParse(futDates[i]);
        if (d == null) continue;
        final p = i < futPrecip.length ? futPrecip[i] : 0.0;
        if (p >= _rainThresholdMm) {
          daysUntil = DateTime(d.year, d.month, d.day).difference(day).inDays;
          if (daysUntil < 0) continue;
          break;
        }
      }

      double? precipToday;
      final todayIdx = histDates.indexWhere((t) => t.startsWith(endStr));
      if (todayIdx >= 0 && todayIdx < histPrecip.length) {
        precipToday = histPrecip[todayIdx];
      } else {
        final fIdx = futDates.indexWhere((t) => t.startsWith(endStr));
        if (fIdx >= 0 && fIdx < futPrecip.length) {
          precipToday = futPrecip[fIdx];
        }
      }

      final current = forecast['current'];
      double? tempC;
      int? code;
      if (current is Map) {
        tempC = (current['temperature_2m'] as num?)?.toDouble();
        code = (current['weather_code'] as num?)?.toInt();
      }

      return JobWeather(
        tempC: tempC,
        precipMm: precipToday,
        weatherCode: code,
        daysSinceRain: daysSince,
        daysUntilRain: daysUntil,
        fetchedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) => e.toString()).toList();
  }

  static List<double> _numList(dynamic raw) {
    if (raw is! List) return const [];
    return raw.map((e) => (e as num?)?.toDouble() ?? 0.0).toList();
  }
}
