/// Tool / implement dimensions (values in current display units: m or ft).
class ToolSetupDimensions {
  const ToolSetupDimensions({
    this.width = 3.0,
    this.boomLateralOffset = 0.0,
    this.gpsLateralOffset = 0.0,
    this.hitchToAxle = 3.0,
  });

  /// No fixed GPS-to-hitch offset; hitch length is user-defined only.
  static const double kGpsPivotOffset = 0.0;

  final double width;
  final double boomLateralOffset;
  final double gpsLateralOffset;
  final double hitchToAxle;

  ToolSetupDimensions copyWith({
    double? width,
    double? boomLateralOffset,
    double? gpsLateralOffset,
    double? hitchToAxle,
  }) {
    return ToolSetupDimensions(
      width: width ?? this.width,
      boomLateralOffset: boomLateralOffset ?? this.boomLateralOffset,
      gpsLateralOffset: gpsLateralOffset ?? this.gpsLateralOffset,
      hitchToAxle: hitchToAxle ?? this.hitchToAxle,
    );
  }

  Map<String, dynamic> toJson() => {
    'width': width,
    'boomLateralOffset': boomLateralOffset,
    'gpsLateralOffset': gpsLateralOffset,
    'hitchToAxle': hitchToAxle,
  };

  factory ToolSetupDimensions.fromJson(Map<String, dynamic> j) {
    return ToolSetupDimensions(
      width: (j['width'] as num?)?.toDouble() ?? 3.0,
      boomLateralOffset: (j['boomLateralOffset'] as num?)?.toDouble() ??
          (j['offset'] as num?)?.toDouble() ??
          0.0,
      gpsLateralOffset: (j['gpsLateralOffset'] as num?)?.toDouble() ?? 0.0,
      hitchToAxle: (j['hitchToAxle'] as num?)?.toDouble() ??
          (j['drawbarLength'] as num?)?.toDouble() ??
          3.0,
    );
  }
}

enum ToolDimField {
  width,
  boomLateralOffset,
  gpsLateralOffset,
  hitchToAxle,
}

extension ToolDimFieldX on ToolDimField {
  String title(String unit) => switch (this) {
    ToolDimField.width => 'Boom width ($unit)',
    ToolDimField.boomLateralOffset => 'Boom lateral offset ($unit)',
    ToolDimField.gpsLateralOffset => 'GPS lateral offset ($unit)',
    ToolDimField.hitchToAxle => 'Hitch length ($unit)',
  };

  String? hint() => switch (this) {
    ToolDimField.gpsLateralOffset => '+ GPS right of centreline',
    ToolDimField.boomLateralOffset => '+ boom right of centre',
    _ => null,
  };

  bool get signed => switch (this) {
    ToolDimField.width => false,
    ToolDimField.hitchToAxle => false,
    _ => true,
  };

  double value(ToolSetupDimensions d) => switch (this) {
    ToolDimField.width => d.width,
    ToolDimField.boomLateralOffset => d.boomLateralOffset,
    ToolDimField.gpsLateralOffset => d.gpsLateralOffset,
    ToolDimField.hitchToAxle => d.hitchToAxle,
  };

  ToolSetupDimensions apply(ToolSetupDimensions d, double v) => switch (this) {
    ToolDimField.width => d.copyWith(width: v),
    ToolDimField.boomLateralOffset => d.copyWith(boomLateralOffset: v),
    ToolDimField.gpsLateralOffset => d.copyWith(gpsLateralOffset: v),
    ToolDimField.hitchToAxle => d.copyWith(hitchToAxle: v),
  };
}
