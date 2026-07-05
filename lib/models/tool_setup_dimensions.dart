import '../services/implement_kinematics.dart';

/// Tool / implement dimensions (values in current display units: m or ft).
class ToolSetupDimensions {
  const ToolSetupDimensions({
    this.width = 3.0,
    this.boomLateralOffset = 0.0,
    this.gpsPivotOffset = 2.0,
    this.gpsLateralOffset = 0.0,
    this.hitchToAxle = 3.0,
    this.axleToBoom = 0.0,
    this.mount = ImplementMount.fixed,
  });

  final double width;
  final double boomLateralOffset;
  final double gpsPivotOffset;
  final double gpsLateralOffset;
  final double hitchToAxle;
  final double axleToBoom;
  final ImplementMount mount;

  ToolSetupDimensions copyWith({
    double? width,
    double? boomLateralOffset,
    double? gpsPivotOffset,
    double? gpsLateralOffset,
    double? hitchToAxle,
    double? axleToBoom,
    ImplementMount? mount,
  }) {
    return ToolSetupDimensions(
      width: width ?? this.width,
      boomLateralOffset: boomLateralOffset ?? this.boomLateralOffset,
      gpsPivotOffset: gpsPivotOffset ?? this.gpsPivotOffset,
      gpsLateralOffset: gpsLateralOffset ?? this.gpsLateralOffset,
      hitchToAxle: hitchToAxle ?? this.hitchToAxle,
      axleToBoom: axleToBoom ?? this.axleToBoom,
      mount: mount ?? this.mount,
    );
  }

  Map<String, dynamic> toJson() => {
    'width': width,
    'boomLateralOffset': boomLateralOffset,
    'gpsPivotOffset': gpsPivotOffset,
    'gpsLateralOffset': gpsLateralOffset,
    'hitchToAxle': hitchToAxle,
    'axleToBoom': axleToBoom,
    'implementTrailed': mount == ImplementMount.trailed,
  };

  factory ToolSetupDimensions.fromJson(Map<String, dynamic> j) {
    return ToolSetupDimensions(
      width: (j['width'] as num?)?.toDouble() ?? 3.0,
      boomLateralOffset: (j['boomLateralOffset'] as num?)?.toDouble() ??
          (j['offset'] as num?)?.toDouble() ??
          0.0,
      gpsPivotOffset: (j['gpsPivotOffset'] as num?)?.toDouble() ?? 2.0,
      gpsLateralOffset: (j['gpsLateralOffset'] as num?)?.toDouble() ?? 0.0,
      hitchToAxle: (j['hitchToAxle'] as num?)?.toDouble() ??
          (j['drawbarLength'] as num?)?.toDouble() ??
          3.0,
      axleToBoom: (j['axleToBoom'] as num?)?.toDouble() ?? 0.0,
      mount: j['implementTrailed'] == true ? ImplementMount.trailed : ImplementMount.fixed,
    );
  }
}

enum ToolDimField {
  width,
  boomLateralOffset,
  gpsPivotOffset,
  gpsLateralOffset,
  hitchToAxle,
  axleToBoom,
}

extension ToolDimFieldX on ToolDimField {
  String title(String unit) => switch (this) {
    ToolDimField.width => 'Working width ($unit)',
    ToolDimField.boomLateralOffset => 'Boom lateral offset ($unit)',
    ToolDimField.gpsPivotOffset => 'GPS ↔ hitch ($unit)',
    ToolDimField.gpsLateralOffset => 'GPS lateral offset ($unit)',
    ToolDimField.hitchToAxle => 'Hitch → axle ($unit)',
    ToolDimField.axleToBoom => 'Axle → boom ($unit)',
  };

  String? hint() => switch (this) {
    ToolDimField.gpsPivotOffset => '+ GPS ahead of hitch',
    ToolDimField.gpsLateralOffset => '+ GPS right of centreline',
    ToolDimField.boomLateralOffset => '+ boom right of centre',
    _ => null,
  };

  bool get signed => switch (this) {
    ToolDimField.width => false,
    ToolDimField.hitchToAxle => false,
    ToolDimField.axleToBoom => false,
    _ => true,
  };

  double value(ToolSetupDimensions d) => switch (this) {
    ToolDimField.width => d.width,
    ToolDimField.boomLateralOffset => d.boomLateralOffset,
    ToolDimField.gpsPivotOffset => d.gpsPivotOffset,
    ToolDimField.gpsLateralOffset => d.gpsLateralOffset,
    ToolDimField.hitchToAxle => d.hitchToAxle,
    ToolDimField.axleToBoom => d.axleToBoom,
  };

  ToolSetupDimensions apply(ToolSetupDimensions d, double v) => switch (this) {
    ToolDimField.width => d.copyWith(width: v),
    ToolDimField.boomLateralOffset => d.copyWith(boomLateralOffset: v),
    ToolDimField.gpsPivotOffset => d.copyWith(gpsPivotOffset: v),
    ToolDimField.gpsLateralOffset => d.copyWith(gpsLateralOffset: v),
    ToolDimField.hitchToAxle => d.copyWith(hitchToAxle: v),
    ToolDimField.axleToBoom => d.copyWith(axleToBoom: v),
  };
}
