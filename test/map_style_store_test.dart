import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tractorgps/services/map_style_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults match the previously hardcoded appearance', () async {
    SharedPreferences.setMockInitialValues({});
    final loaded = await MapStyle.load();

    // Persisted colours come back as plain Color, while defaults are Material
    // swatches - compare the packed value, not the runtime type.
    expect(
      loaded.swathColor.toARGB32(),
      MapStyle.defaults().swathColor.toARGB32(),
    );
    expect(loaded.swathOpacity, closeTo(0.55, 1e-9));
    expect(loaded.paddockFillOpacity, closeTo(0.20, 1e-9));
  });

  test('save/load round-trips colours and opacity', () async {
    SharedPreferences.setMockInitialValues({});

    final edited = MapStyle.defaults().copyWith(
      swathColor: Colors.red,
      swathOpacity: 0.30,
      cursorColor: Colors.black,
      paddockSelectedColor: Colors.pink,
    );
    await edited.save();

    final loaded = await MapStyle.load();
    expect(loaded.swathColor.toARGB32(), Colors.red.toARGB32());
    expect(loaded.swathOpacity, closeTo(0.30, 1e-9));
    expect(loaded.cursorColor.toARGB32(), Colors.black.toARGB32());
    expect(loaded.paddockSelectedColor.toARGB32(), Colors.pink.toARGB32());

    // Untouched values keep their defaults rather than resetting.
    expect(
      loaded.guidanceColor.toARGB32(),
      MapStyle.defaults().guidanceColor.toARGB32(),
    );
    expect(loaded.paddockFillOpacity,
        closeTo(MapStyle.defaults().paddockFillOpacity, 1e-9));
  });

  test('out-of-range opacity is clamped on load', () async {
    SharedPreferences.setMockInitialValues({
      MapStyle.swathOpacityKey: 4.0,
      MapStyle.trackOpacityKey: -2.0,
    });

    final loaded = await MapStyle.load();
    expect(loaded.swathOpacity, 1.0);
    expect(loaded.trackOpacity, 0.0);
  });

  test('colour keys are exposed for the backup whitelist', () {
    // The backup restore path needs to know these are ints, not doubles.
    expect(MapStyle.colorKeys, contains(MapStyle.swathColorKey));
    expect(MapStyle.opacityKeys, contains(MapStyle.swathOpacityKey));
    expect(MapStyle.colorKeys.length, 10);
    expect(MapStyle.opacityKeys.length, 5);
  });
}
