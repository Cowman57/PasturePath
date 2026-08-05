import 'package:shared_preferences/shared_preferences.dart';

/// Last Start Load values used as grey placeholders for repeat jobs.
class LastLoadPrefs {
  static const _kUnit = 'lastLoad_unit';
  static const _kName = 'lastLoad_productName';
  static const _kStart = 'lastLoad_startQty';
  static const _kRate = 'lastLoad_targetRate';
  static const _kProductKg = 'lastLoad_productKg';
  static const _kProductRate = 'lastLoad_productRate';
  static const _kDissolved = 'lastLoad_dissolved';

  final String unit;
  final String? productName;
  final double startQty;
  /// Carrier rate (kg/ha or L/ha) stored on the session.
  final double targetRatePerHa;
  final double? productLoadedKg;
  /// Primary operator rate shown in the dialog (product kg/ha when dissolved).
  final double primaryRatePerHa;
  final bool dissolved;

  const LastLoadPrefs({
    required this.unit,
    required this.startQty,
    required this.targetRatePerHa,
    required this.primaryRatePerHa,
    this.productName,
    this.productLoadedKg,
    this.dissolved = false,
  });

  static Future<LastLoadPrefs?> load() async {
    final p = await SharedPreferences.getInstance();
    final start = p.getDouble(_kStart);
    final rate = p.getDouble(_kRate);
    final primary = p.getDouble(_kProductRate) ?? rate;
    if (start == null || rate == null || primary == null) return null;
    return LastLoadPrefs(
      unit: p.getString(_kUnit) == 'L' ? 'L' : 'kg',
      productName: p.getString(_kName),
      startQty: start,
      targetRatePerHa: rate,
      productLoadedKg: p.getDouble(_kProductKg),
      primaryRatePerHa: primary,
      dissolved: p.getBool(_kDissolved) ?? false,
    );
  }

  static Future<void> save({
    required String unit,
    required double startQty,
    required double targetRatePerHa,
    required double primaryRatePerHa,
    String? productName,
    double? productLoadedKg,
    bool dissolved = false,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUnit, unit == 'L' ? 'L' : 'kg');
    final name = productName?.trim();
    if (name != null && name.isNotEmpty) {
      await p.setString(_kName, name);
    } else {
      await p.remove(_kName);
    }
    await p.setDouble(_kStart, startQty);
    await p.setDouble(_kRate, targetRatePerHa);
    await p.setDouble(_kProductRate, primaryRatePerHa);
    await p.setBool(_kDissolved, dissolved);
    if (productLoadedKg != null && productLoadedKg > 0) {
      await p.setDouble(_kProductKg, productLoadedKg);
    } else {
      await p.remove(_kProductKg);
    }
  }
}
