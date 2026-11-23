import 'paddock.dart';

/// Planned paddocks for a spreading/spraying run.
///
/// Product, unit and target rate belong to the load session (the load button),
/// not to this list — this is only "which paddocks are still to do".
class PaddockWorkList {
  PaddockWorkList({
    List<String>? paddockNames,
    Set<String>? completedNames,
  })  : paddockNames = List<String>.from(paddockNames ?? const []),
        completedNames = Set<String>.from(completedNames ?? const {});

  final List<String> paddockNames;
  final Set<String> completedNames;

  bool get isEmpty => paddockNames.isEmpty;
  bool get isNotEmpty => paddockNames.isNotEmpty;
  int get paddockCount => paddockNames.length;

  int get completedCount =>
      paddockNames.where(completedNames.contains).length;

  bool contains(String name) => paddockNames.contains(name);

  bool containsAll(Iterable<String> names) {
    for (final n in names) {
      if (!paddockNames.contains(n)) return false;
    }
    return names.isNotEmpty;
  }

  /// Returns how many names were newly added.
  int addNames(Iterable<String> names) {
    var added = 0;
    for (final raw in names) {
      final name = raw.trim();
      if (name.isEmpty || paddockNames.contains(name)) continue;
      paddockNames.add(name);
      added++;
    }
    return added;
  }

  void removeName(String name) {
    paddockNames.remove(name);
    completedNames.remove(name);
  }

  int removeNames(Iterable<String> names) {
    var n = 0;
    for (final name in names) {
      if (paddockNames.remove(name)) n++;
      completedNames.remove(name);
    }
    return n;
  }

  void markCompleted(Iterable<String> names) {
    for (final name in names) {
      if (paddockNames.contains(name)) completedNames.add(name);
    }
  }

  void clear() {
    paddockNames.clear();
    completedNames.clear();
  }

  /// Drop names that no longer exist on the farm map.
  void pruneMissing(Iterable<String> existingNames) {
    final live = existingNames.toSet();
    paddockNames.removeWhere((n) => !live.contains(n));
    completedNames.removeWhere((n) => !live.contains(n));
  }

  double totalHa(List<Paddock> paddocks) =>
      _sumHa(paddocks, paddockNames);

  double completedHa(List<Paddock> paddocks) => _sumHa(
        paddocks,
        paddockNames.where(completedNames.contains),
      );

  double remainingHa(List<Paddock> paddocks) {
    final left = totalHa(paddocks) - completedHa(paddocks);
    return left < 0 ? 0 : left;
  }

  static double _sumHa(List<Paddock> paddocks, Iterable<String> names) {
    final want = names.toSet();
    if (want.isEmpty) return 0;
    var ha = 0.0;
    for (final p in paddocks) {
      if (want.contains(p.name)) ha += p.areaHa;
    }
    return ha;
  }

  Map<String, dynamic> toJson() => {
        'paddockNames': paddockNames,
        'completedNames': completedNames.toList()..sort(),
      };

  factory PaddockWorkList.fromJson(Map<String, dynamic> j) {
    final names = <String>[];
    final rawNames = j['paddockNames'];
    if (rawNames is List) {
      for (final e in rawNames) {
        final n = e.toString().trim();
        if (n.isNotEmpty && !names.contains(n)) names.add(n);
      }
    }
    final done = <String>{};
    final rawDone = j['completedNames'];
    if (rawDone is List) {
      for (final e in rawDone) {
        final n = e.toString().trim();
        if (n.isNotEmpty) done.add(n);
      }
    }
    // Lists saved by older versions carried unit/product/rate here. Those now
    // live on the load session, so legacy keys are ignored on read.
    return PaddockWorkList(
      paddockNames: names,
      completedNames: done,
    );
  }
}
