import 'package:flutter_test/flutter_test.dart';
import 'package:tractorgps/models/load_session.dart';

void main() {
  group('LoadSession.withoutJob', () {
    LoadSession build({bool closed = false}) => LoadSession(
          id: 'load-1',
          unit: 'kg',
          startQty: 2000,
          endQty: closed ? 1500 : null,
          targetRatePerHa: 100,
          startedAt: DateTime(2026, 8, 1),
          endedAt: closed ? DateTime(2026, 8, 1, 3) : null,
          jobs: const [
            LoadSessionJobRef(jobId: 'a', appliedHa: 2.0),
            LoadSessionJobRef(jobId: 'b', appliedHa: 3.0),
          ],
        );

    test('drops the deleted job from applied and pending ha', () {
      final s = build();
      expect(s.totalAppliedHa, closeTo(5.0, 0.001));
      expect(s.pendingAppliedHa, closeTo(5.0, 0.001));
      expect(s.expectedQtyNow, closeTo(1500, 0.001)); // 2000 - 100*5

      final after = s.withoutJob('a');

      expect(after.jobs.length, 1);
      expect(after.jobs.single.jobId, 'b');
      expect(after.totalAppliedHa, closeTo(3.0, 0.001));
      expect(after.pendingAppliedHa, closeTo(3.0, 0.001));
      // Expected scales no longer deduct the deleted job's area.
      expect(after.expectedQtyNow, closeTo(1700, 0.001)); // 2000 - 100*3

      // Nothing else moves.
      expect(after.id, s.id);
      expect(after.startQty, s.startQty);
      expect(after.currentQty, s.currentQty);
      expect(after.usedQty, s.usedQty);
      expect(after.isOpen, isTrue);
    });

    test('remaining job keeps its share of the used qty on a closed session',
        () {
      final s = build(closed: true);
      expect(s.usedQty, closeTo(500, 0.001));
      expect(s.amountForJob('b'), closeTo(300, 0.001)); // 500 * 3/5

      final after = s.withoutJob('a');

      expect(after.usedQty, closeTo(500, 0.001)); // usage itself unchanged
      expect(after.totalAppliedHa, closeTo(3.0, 0.001));
      expect(after.amountForJob('a'), isNull);
      expect(after.amountForJob('b')!, greaterThan(300));
      expect(after.amountForJob('b'), closeTo(500, 0.001)); // 500 * 3/3
    });

    test('unknown job id is a no-op', () {
      final s = build();
      final after = s.withoutJob('does-not-exist');

      expect(after.jobs.length, 2);
      expect(after.totalAppliedHa, closeTo(s.totalAppliedHa, 0.001));
      expect(after.pendingAppliedHa, closeTo(s.pendingAppliedHa, 0.001));
      expect(after.expectedQtyNow, closeTo(s.expectedQtyNow, 0.001));
    });
  });
}
