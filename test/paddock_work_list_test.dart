import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tractorgps/models/paddock.dart';
import 'package:tractorgps/models/paddock_work_list.dart';

Paddock _p(String name, double ha) => Paddock(
      name: name,
      outer: const [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1)],
      holes: const [],
      areaHa: ha,
      labelPoint: const LatLng(0.5, 0.5),
    );

void main() {
  test('add is unique and totals paddock given area', () {
    final list = PaddockWorkList();
    expect(list.addNames(const ['A', 'B', 'A']), 2);
    final paddocks = [_p('A', 10), _p('B', 6), _p('C', 99)];
    expect(list.totalHa(paddocks), closeTo(16, 0.01));
    expect(list.paddockCount, 2);
    expect(list.completedCount, 0);
  });

  test('completed ha and remaining expected qty use given area', () {
    final list = PaddockWorkList(
      paddockNames: const ['A', 'B', 'C'],
      targetRatePerHa: 80,
    );
    list.markCompleted(const ['A', 'B']);
    final paddocks = [_p('A', 10), _p('B', 3), _p('C', 3)];
    expect(list.completedCount, 2);
    expect(list.completedHa(paddocks), closeTo(13, 0.01));
    expect(list.totalHa(paddocks), closeTo(16, 0.01));
    expect(list.remainingHa(paddocks), closeTo(3, 0.01));
    expect(list.expectedRemainingQty(paddocks), closeTo(240, 0.01));
  });

  test('json round trip keeps order and completed set', () {
    final list = PaddockWorkList(
      paddockNames: const ['North', 'South'],
      completedNames: const {'North'},
      unit: 'L',
      targetRatePerHa: 100,
      productName: 'Urea',
    );
    final copy = PaddockWorkList.fromJson(list.toJson());
    expect(copy.paddockNames, ['North', 'South']);
    expect(copy.completedNames, {'North'});
    expect(copy.unit, 'L');
    expect(copy.targetRatePerHa, 100);
    expect(copy.productName, 'Urea');
  });
}
