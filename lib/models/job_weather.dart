/// Weather / rainfall context captured at job finish.
class JobWeather {
  const JobWeather({
    this.tempC,
    this.precipMm,
    this.weatherCode,
    this.daysSinceRain,
    this.daysUntilRain,
    this.fetchedAt,
  });

  final double? tempC;
  /// Precipitation on the job day (mm).
  final double? precipMm;
  /// WMO weather interpretation code (Open-Meteo).
  final int? weatherCode;
  /// Whole days since last day with ≥0.5 mm rain (null if unknown / none in window).
  final int? daysSinceRain;
  /// Whole days until next forecast day with ≥0.5 mm (null if none in forecast).
  final int? daysUntilRain;
  final DateTime? fetchedAt;

  String get shortLabel {
    final parts = <String>[];
    if (tempC != null) parts.add('${tempC!.round()}°C');
    if (daysSinceRain != null) {
      parts.add(
        daysSinceRain == 0 ? 'rained today' : '${daysSinceRain}d since rain',
      );
    }
    if (daysUntilRain != null) {
      parts.add(
        daysUntilRain == 0 ? 'rain today' : 'rain in ${daysUntilRain}d',
      );
    }
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        if (tempC != null) 'tempC': tempC,
        if (precipMm != null) 'precipMm': precipMm,
        if (weatherCode != null) 'weatherCode': weatherCode,
        if (daysSinceRain != null) 'daysSinceRain': daysSinceRain,
        if (daysUntilRain != null) 'daysUntilRain': daysUntilRain,
        if (fetchedAt != null) 'fetchedAt': fetchedAt!.toIso8601String(),
      };

  factory JobWeather.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const JobWeather();
    return JobWeather(
      tempC: (j['tempC'] as num?)?.toDouble(),
      precipMm: (j['precipMm'] as num?)?.toDouble(),
      weatherCode: (j['weatherCode'] as num?)?.toInt(),
      daysSinceRain: (j['daysSinceRain'] as num?)?.toInt(),
      daysUntilRain: (j['daysUntilRain'] as num?)?.toInt(),
      fetchedAt: DateTime.tryParse(j['fetchedAt'] as String? ?? ''),
    );
  }
}
