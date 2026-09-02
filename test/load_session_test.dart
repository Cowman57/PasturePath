import 'package:flutter_test/flutter_test.dart';
import 'package:tractorgps/models/load_session.dart';

void main() {
  group('LoadSession', () {
    test('expected scales falls with applied ha at target rate', () {
      final s = LoadSession(
        id: '1',
        unit: 'kg',
        startQty: 2000,
        targetRatePerHa: 100,
        startedAt: DateTime(2026, 8, 1),
        jobs: const [
          LoadSessionJobRef(jobId: 'a', appliedHa: 2.0),
          LoadSessionJobRef(jobId: 'b', appliedHa: 3.0),
        ],
      );
      expect(s.expectedQtyNow, closeTo(1500, 0.01)); // 2000 - 100*5
    });

    test('closed session allocates by applied ha', () {
      final s = LoadSession(
        id: '1',
        unit: 'kg',
        startQty: 2000,
        endQty: 1500,
        targetRatePerHa: 100,
        startedAt: DateTime(2026, 8, 1),
        endedAt: DateTime(2026, 8, 1, 2),
        jobs: const [
          LoadSessionJobRef(jobId: 'a', appliedHa: 2.0),
          LoadSessionJobRef(jobId: 'b', appliedHa: 3.0),
        ],
      );
      expect(s.usedQty, closeTo(500, 0.01));
      expect(s.actualRatePerHa, closeTo(100, 0.01)); // 500/5
      expect(s.amountForJob('a'), closeTo(200, 0.01));
      expect(s.amountForJob('b'), closeTo(300, 0.01));
    });

    test('dissolved load derives product rate from kg and litres used', () {
      final s = LoadSession(
        id: '1',
        unit: 'L',
        productName: 'Urea',
        startQty: 3000,
        endQty: 0,
        targetRatePerHa: 100,
        productLoadedKg: 900,
        targetProductRatePerHa: 30,
        startedAt: DateTime(2026, 8, 1),
        endedAt: DateTime(2026, 8, 1, 2),
        jobs: const [
          LoadSessionJobRef(jobId: 'a', appliedHa: 20.0),
          LoadSessionJobRef(jobId: 'b', appliedHa: 10.0),
        ],
      );
      expect(s.usedQty, closeTo(3000, 0.01));
      expect(s.actualRatePerHa, closeTo(100, 0.01)); // 3000 L / 30 ha
      expect(s.productUsedKg, closeTo(900, 0.01));
      expect(s.actualProductRatePerHa, closeTo(30, 0.01)); // 900/30
      expect(s.productAmountForJob('a'), closeTo(600, 0.01));
      expect(s.productAmountForJob('b'), closeTo(300, 0.01));
    });

    test('partial tank uses product fraction of litres used', () {
      final s = LoadSession(
        id: '1',
        unit: 'L',
        productName: 'Urea',
        startQty: 3000,
        endQty: 1500,
        targetRatePerHa: 100,
        productLoadedKg: 900,
        startedAt: DateTime(2026, 8, 1),
        endedAt: DateTime(2026, 8, 1, 2),
        jobs: const [
          LoadSessionJobRef(jobId: 'a', appliedHa: 15.0),
        ],
      );
      expect(s.productUsedKg, closeTo(450, 0.01)); // half tank
      expect(s.actualProductRatePerHa, closeTo(30, 0.01)); // 450/15
    });

    test('per-paddock reading becomes new start and attributes that job', () {
      final s = LoadSession(
        id: '1',
        unit: 'kg',
        startQty: 2000,
        targetRatePerHa: 100,
        startedAt: DateTime(2026, 8, 1),
        jobs: [
          const LoadSessionJobRef(jobId: 'a', appliedHa: 2.0),
        ],
      );

      s.applyReading(1800); // used 200 on paddock a
      expect(s.currentQty, 1800);
      expect(s.amountForJob('a'), closeTo(200, 0.01));
      expect(s.rateForJob('a'), closeTo(100, 0.01));
      expect(s.jobs.single.hasReading, isTrue);

      s.jobs.add(const LoadSessionJobRef(jobId: 'b', appliedHa: 3.0));
      expect(s.pendingAppliedHa, closeTo(3.0, 0.01));
      expect(s.expectedQtyNow, closeTo(1500, 0.01)); // 1800 - 100*3

      s.applyReading(1500); // used 300 on paddock b
      expect(s.currentQty, 1500);
      expect(s.amountForJob('b'), closeTo(300, 0.01));
      expect(s.rateForJob('b'), closeTo(100, 0.01));
      expect(s.measuredUsedQty, closeTo(500, 0.01));
    });

    test('reading with two pending jobs shares by ha', () {
      final s = LoadSession(
        id: '1',
        unit: 'kg',
        startQty: 2000,
        targetRatePerHa: 100,
        startedAt: DateTime(2026, 8, 1),
        jobs: const [
          LoadSessionJobRef(jobId: 'a', appliedHa: 2.0),
          LoadSessionJobRef(jobId: 'b', appliedHa: 3.0),
        ],
      );
      s.applyReading(1500);
      expect(s.amountForJob('a'), closeTo(200, 0.01));
      expect(s.amountForJob('b'), closeTo(300, 0.01));
      expect(s.currentQty, 1500);
    });
    test('closeWithExpectedRemaining attributes pending at expected qty', () {
      final s = LoadSession(
        id: '1',
        unit: 'kg',
        startQty: 2000,
        targetRatePerHa: 100,
        startedAt: DateTime(2026, 8, 1),
        jobs: [
          const LoadSessionJobRef(jobId: 'a', appliedHa: 2.0, usedQty: 200),
          const LoadSessionJobRef(jobId: 'b', appliedHa: 3.0),
        ],
      );
      // current start after job a reading would be 1800; simulate that:
      s.currentQty = 1800;
      expect(s.expectedQtyNow, closeTo(1500, 0.01)); // 1800 - 100*3
      s.closeWithExpectedRemaining();
      expect(s.jobs[0].usedQty, closeTo(200, 0.01));
      expect(s.jobs[1].usedQty, closeTo(300, 0.01));
      expect(s.currentQty, closeTo(1500, 0.01));
    });

    test('rate uses paddock given area not covered swath', () {
      final s = LoadSession(
        id: '1',
        unit: 'kg',
        startQty: 2000,
        targetRatePerHa: 100,
        startedAt: DateTime(2026, 8, 1),
        jobs: const [
          LoadSessionJobRef(jobId: 'a', appliedHa: 2.0, paddockHa: 10.0),
        ],
      );
      s.applyReading(1800); // used 200
      expect(s.amountForJob('a'), closeTo(200, 0.01));
      expect(s.rateForJob('a'), closeTo(20, 0.01)); // 200 / 10 ha paddock
      expect(s.expectedQtyNow, closeTo(1800, 0.01));
    });

    test('expected remaining uses paddock area once a job is attached', () {
      final s = LoadSession(
        id: '1',
        unit: 'kg',
        startQty: 2000,
        targetRatePerHa: 100,
        startedAt: DateTime(2026, 8, 1),
        jobs: const [
          LoadSessionJobRef(jobId: 'a', appliedHa: 2.0, paddockHa: 10.0),
        ],
      );
      expect(s.pendingAppliedHa, closeTo(10.0, 0.01));
      expect(s.expectedQtyNow, closeTo(1000, 0.01)); // 2000 - 100*10
    });
  });

  group('paddockJobShare', () {
    test('single paddock job is full share', () {
      expect(
        paddockJobShare(
          paddockNames: const ['A'],
          paddockName: 'A',
          jobTotalHa: 10,
          paddockAreaHa: 10,
        ),
        1.0,
      );
    });

    test('multi paddock pro-rates by area', () {
      expect(
        paddockJobShare(
          paddockNames: const ['A', 'B'],
          paddockName: 'A',
          jobTotalHa: 30,
          paddockAreaHa: 10,
        ),
        closeTo(10 / 30, 1e-9),
      );
    });
  });

  group('JobProductStats', () {
    test('labels stay compact for history', () {
      const s = JobProductStats(
        amount: 120,
        ratePerHa: 30,
        unit: 'L',
        productName: 'Urea',
        carrierAmount: 400,
        carrierRatePerHa: 100,
      );
      expect(s.shortLabel, 'Urea 30 kg/ha');
      expect(s.historyLabel, '30 kg/ha');
      expect(s.recordUnitLabel, 'kg');
    });
  });
}
