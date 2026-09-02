/// One job finished while a product load was open.
class LoadSessionJobRef {
  const LoadSessionJobRef({
    required this.jobId,
    required this.appliedHa,
    this.paddockHa,
    this.usedQty,
  });

  final String jobId;

  /// Swath area actually covered (ha). Used for coverage / speed advice.
  final double appliedHa;

  /// Paddock given area (ha) this job belongs to. Rate and expected remaining
  /// use this so leaving a paddock mid-job does not shrink the denominator.
  final double? paddockHa;

  /// Carrier used for this job from a scale reading (kg or L).
  /// Null until a reading attributes usage to this job.
  final double? usedQty;

  /// Area the recorded rate applies to: paddock given area when known.
  double get rateAreaHa {
    final given = paddockHa;
    if (given != null && given > 0) return given;
    return appliedHa > 0 ? appliedHa : 0;
  }

  bool get hasReading => usedQty != null;

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'appliedHa': appliedHa,
        if (paddockHa != null) 'paddockHa': paddockHa,
        if (usedQty != null) 'usedQty': usedQty,
      };

  factory LoadSessionJobRef.fromJson(Map<String, dynamic> j) {
    return LoadSessionJobRef(
      jobId: j['jobId'] as String? ?? '',
      appliedHa: (j['appliedHa'] as num?)?.toDouble() ?? 0,
      paddockHa: (j['paddockHa'] as num?)?.toDouble(),
      usedQty: (j['usedQty'] as num?)?.toDouble(),
    );
  }

  LoadSessionJobRef copyWith({
    String? jobId,
    double? appliedHa,
    double? paddockHa,
    double? usedQty,
    bool clearUsedQty = false,
  }) {
    return LoadSessionJobRef(
      jobId: jobId ?? this.jobId,
      appliedHa: appliedHa ?? this.appliedHa,
      paddockHa: paddockHa ?? this.paddockHa,
      usedQty: clearUsedQty ? null : (usedQty ?? this.usedQty),
    );
  }
}

/// Start/end scale readings spanning one or more finished jobs.
///
/// Scale readings can be logged after each paddock/job without ending the load:
/// each reading attributes usage since [currentQty], then becomes the new start.
class LoadSession {
  LoadSession({
    required this.id,
    required this.unit,
    required this.startQty,
    required this.targetRatePerHa,
    required this.startedAt,
    double? currentQty,
    this.productName,
    this.productLoadedKg,
    this.targetProductRatePerHa,
    this.endQty,
    this.endedAt,
    List<LoadSessionJobRef>? jobs,
  })  : currentQty = currentQty ?? startQty,
        jobs = List<LoadSessionJobRef>.from(jobs ?? const []);

  final String id;

  /// `'kg'` or `'L'`.
  final String unit;

  /// Original fill / first reading for this load.
  final double startQty;

  /// Latest scale reading — start of the current open segment.
  /// Updated each time a reading is recorded; becomes the new start weight.
  double currentQty;

  final double? endQty;
  final double targetRatePerHa;
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<LoadSessionJobRef> jobs;

  /// Optional product label (e.g. Urea, DAP).
  final String? productName;

  /// When spraying a dissolved product (`unit == 'L'`): kg of product mixed
  /// into this tank fill. Used to derive product rate for records.
  final double? productLoadedKg;

  /// Optional target solid rate (kg/ha) when spraying dissolved product.
  final double? targetProductRatePerHa;

  bool get isOpen => endedAt == null;

  bool get isDissolved => unit == 'L' && (productLoadedKg ?? 0) > 0;

  double get totalAppliedHa =>
      jobs.fold(0.0, (s, j) => s + j.rateAreaHa);

  /// Ha on jobs not yet attributed a scale reading.
  double get pendingAppliedHa => jobs
      .where((j) => !j.hasReading)
      .fold(0.0, (s, j) => s + j.rateAreaHa);

  /// Expected scales for the open segment (from [currentQty]).
  double expectedQtyForAppliedHa(double appliedHa) =>
      currentQty - targetRatePerHa * appliedHa;

  double get expectedQtyNow => expectedQtyForAppliedHa(pendingAppliedHa);

  /// Carrier used attributed so far (sum of per-job readings).
  double get measuredUsedQty => jobs.fold(
        0.0,
        (s, j) => s + (j.usedQty ?? 0),
      );

  /// Total carrier used. Closed loads: initial start − final end.
  /// Open loads with readings: measured so far (+ pending estimated if needed).
  double? get usedQty {
    final end = endQty;
    if (end != null) return startQty - end;
    if (measuredUsedQty > 0) return measuredUsedQty;
    return null;
  }

  /// Actual average carrier rate (`used / totalHa`).
  double? get actualRatePerHa {
    final used = usedQty;
    final ha = totalAppliedHa;
    if (used == null || ha <= 0) return null;
    return used / ha;
  }

  /// Product kg used (pro-rata by carrier used vs original fill).
  double? get productUsedKg {
    final loaded = productLoadedKg;
    if (loaded == null || loaded <= 0) return null;
    final used = usedQty;
    if (used == null) return null;
    if (startQty <= 0) return loaded;
    final frac = (used / startQty).clamp(0.0, 1.0);
    return loaded * frac;
  }

  /// Actual product (solid) rate after enough readings / close.
  double? get actualProductRatePerHa {
    final used = productUsedKg;
    final ha = totalAppliedHa;
    if (used == null || ha <= 0) return null;
    return used / ha;
  }

  /// Attribute [delta] carrier across pending jobs by applied ha.
  /// Returns updated job list (does not mutate if nothing pending).
  List<LoadSessionJobRef> _attributeDeltaToPending(double delta) {
    final pending = jobs.where((j) => !j.hasReading).toList();
    if (pending.isEmpty) return List<LoadSessionJobRef>.from(jobs);

    final pendingHa = pending.fold(
      0.0,
      (s, j) => s + j.rateAreaHa,
    );

    final lastPendingId = pending.last.jobId;

    return jobs.map((j) {
      if (j.hasReading) return j;
      if (pendingHa <= 0) {
        // No ha yet — put all on the last pending job only.
        if (j.jobId == lastPendingId) {
          return j.copyWith(usedQty: delta);
        }
        return j.copyWith(usedQty: 0);
      }
      final share = j.rateAreaHa > 0 ? j.rateAreaHa / pendingHa : 0.0;
      return j.copyWith(usedQty: delta * share);
    }).toList();
  }

  /// Apply a scale reading: attribute usage since [currentQty], then set
  /// [currentQty] = [reading]. Load stays open.
  ///
  /// If there are no pending jobs, still advances [currentQty] (e.g. mid-paddock
  /// check) without attributing usage.
  void applyReading(double reading) {
    final delta = currentQty - reading;
    if (pendingAppliedHa > 0 || jobs.any((j) => !j.hasReading)) {
      final updated = _attributeDeltaToPending(delta);
      jobs
        ..clear()
        ..addAll(updated);
    }
    currentQty = reading;
  }

  double? amountForJob(String jobId) {
    final match = _job(jobId);
    if (match == null) return null;
    if (match.usedQty != null) return match.usedQty;

    // Fallback: closed load without per-job readings — share by ha.
    final used = usedQty;
    final ha = totalAppliedHa;
    if (used == null || ha <= 0) return null;
    if (match.rateAreaHa <= 0) return null;
    return used * match.rateAreaHa / ha;
  }

  double? productAmountForJob(String jobId) {
    final carrier = amountForJob(jobId);
    final loaded = productLoadedKg;
    if (carrier == null || loaded == null || loaded <= 0) return null;
    if (startQty <= 0) return null;
    return loaded * (carrier / startQty);
  }

  double? rateForJob(String jobId) {
    final match = _job(jobId);
    final amount = amountForJob(jobId);
    if (match == null || amount == null || match.rateAreaHa <= 0) return null;
    return amount / match.rateAreaHa;
  }

  double? productRateForJob(String jobId) {
    final match = _job(jobId);
    final amount = productAmountForJob(jobId);
    if (match == null || amount == null || match.rateAreaHa <= 0) return null;
    return amount / match.rateAreaHa;
  }

  LoadSessionJobRef? _job(String jobId) {
    for (final j in jobs) {
      if (j.jobId == jobId) return j;
    }
    return null;
  }

  String get unitLabel => unit == 'L' ? 'L' : 'kg';
  String get rateUnitLabel => '$unitLabel/ha';

  String get displayName {
    final n = productName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return unit == 'L' ? 'Spray' : 'Product';
  }

  /// Primary target rate for operator records (product kg/ha when dissolved).
  double get primaryTargetRatePerHa =>
      (targetProductRatePerHa != null && targetProductRatePerHa! > 0)
          ? targetProductRatePerHa!
          : targetRatePerHa;

  String get primaryTargetRateLabel {
    if (targetProductRatePerHa != null && targetProductRatePerHa! > 0) {
      return '${targetProductRatePerHa!.toStringAsFixed(0)} kg/ha';
    }
    return '${targetRatePerHa.toStringAsFixed(0)} $rateUnitLabel';
  }

  /// Close without a weighed reading: attribute pending jobs at expected remaining.
  void closeWithExpectedRemaining() {
    final expected = expectedQtyNow.clamp(0.0, currentQty);
    applyReading(expected);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'unit': unit,
        'startQty': startQty,
        'currentQty': currentQty,
        'endQty': endQty,
        'targetRatePerHa': targetRatePerHa,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'jobs': jobs.map((j) => j.toJson()).toList(),
        if (productName != null && productName!.trim().isNotEmpty)
          'productName': productName!.trim(),
        if (productLoadedKg != null) 'productLoadedKg': productLoadedKg,
        if (targetProductRatePerHa != null)
          'targetProductRatePerHa': targetProductRatePerHa,
      };

  factory LoadSession.fromJson(Map<String, dynamic> j) {
    final rawJobs = j['jobs'];
    final jobs = <LoadSessionJobRef>[];
    if (rawJobs is List) {
      for (final e in rawJobs) {
        if (e is Map) {
          jobs.add(LoadSessionJobRef.fromJson(e.cast<String, dynamic>()));
        }
      }
    }
    final name = (j['productName'] as String?)?.trim();
    final start = (j['startQty'] as num?)?.toDouble() ?? 0;
    return LoadSession(
      id: j['id'] as String? ?? '',
      unit: (j['unit'] as String?) == 'L' ? 'L' : 'kg',
      startQty: start,
      currentQty: (j['currentQty'] as num?)?.toDouble() ?? start,
      endQty: (j['endQty'] as num?)?.toDouble(),
      targetRatePerHa: (j['targetRatePerHa'] as num?)?.toDouble() ?? 0,
      startedAt: DateTime.tryParse(j['startedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      endedAt: DateTime.tryParse(j['endedAt'] as String? ?? ''),
      jobs: jobs,
      productName: (name != null && name.isNotEmpty) ? name : null,
      productLoadedKg: (j['productLoadedKg'] as num?)?.toDouble(),
      targetProductRatePerHa:
          (j['targetProductRatePerHa'] as num?)?.toDouble(),
    );
  }

  LoadSession copyWith({
    double? currentQty,
    double? endQty,
    DateTime? endedAt,
    List<LoadSessionJobRef>? jobs,
    bool clearEnd = false,
  }) {
    return LoadSession(
      id: id,
      unit: unit,
      startQty: startQty,
      currentQty: currentQty ?? this.currentQty,
      endQty: clearEnd ? null : (endQty ?? this.endQty),
      targetRatePerHa: targetRatePerHa,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      jobs: jobs ?? this.jobs,
      productName: productName,
      productLoadedKg: productLoadedKg,
      targetProductRatePerHa: targetProductRatePerHa,
    );
  }
}

/// Closed-session (or measured) product stats for one job (for history UI).
class JobProductStats {
  const JobProductStats({
    required this.amount,
    required this.ratePerHa,
    required this.unit,
    this.productName,
    this.carrierAmount,
    this.carrierRatePerHa,
  });

  /// Primary amount for records: product kg when dissolved, else carrier qty.
  final double amount;
  final double ratePerHa;
  final String unit;
  final String? productName;

  /// When dissolved: litres applied on this job.
  final double? carrierAmount;
  final double? carrierRatePerHa;

  String get unitLabel => unit == 'L' ? 'L' : 'kg';

  bool get isDissolved => unit == 'L' && carrierAmount != null;

  /// Display unit for the primary (record) amount.
  String get recordUnitLabel => isDissolved ? 'kg' : unitLabel;

  String get displayName {
    final n = productName?.trim();
    if (n != null && n.isNotEmpty) return n;
    return unit == 'L' ? 'Spray' : 'Product';
  }

  String get shortLabel {
    final name = productName?.trim();
    final prefix = (name != null && name.isNotEmpty) ? '$name ' : '';
    return '$prefix${ratePerHa.toStringAsFixed(0)} $recordUnitLabel/ha';
  }

  /// Compact history-table label (rate only).
  String get historyLabel =>
      '${ratePerHa.toStringAsFixed(0)} $recordUnitLabel/ha';
}

/// Applied ha helper matching job coverage math.
double appliedHaForJob({
  required double pathDistanceM,
  required double swathWidthM,
}) {
  if (pathDistanceM <= 0 || swathWidthM <= 0) return 0;
  return pathDistanceM * swathWidthM / 10000.0;
}

/// Share of a multi-paddock job attributed to [paddockAreaHa].
double paddockJobShare({
  required List<String> paddockNames,
  required String paddockName,
  required double jobTotalHa,
  required double paddockAreaHa,
}) {
  if (!paddockNames.contains(paddockName)) return 0;
  if (paddockNames.length <= 1) return 1;
  if (jobTotalHa > 0 && paddockAreaHa > 0) {
    return (paddockAreaHa / jobTotalHa).clamp(0.0, 1.0);
  }
  return 1.0 / paddockNames.length;
}
