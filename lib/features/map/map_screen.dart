// lib/features/map/map_screen.dart
import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app_theme.dart';
import '../../models/paddock.dart';
import '../../models/paddock_work_list.dart';
import '../../models/job.dart';
import '../../models/gps_fix.dart';
import '../../models/load_session.dart';
import '../../services/backup_store.dart';
import '../../services/job_store.dart';
import '../../services/last_load_prefs.dart';
import '../../services/load_session_store.dart';
import '../../services/paddock_work_list_store.dart';
import '../../services/map_tile_cache.dart';
import '../../services/weather_service.dart';
import '../../models/job_weather.dart';
import '../../services/geometry.dart';
import '../../services/geojson_parser.dart';
import '../../services/gps_display_smoother.dart';
import '../../services/gps/gps_input_controller.dart';
import '../../services/gps/gps_source.dart';
import '../../services/implement_kinematics.dart';
import '../../models/tool_setup_dimensions.dart';
import '../../services/tool_preset_store.dart';
import '../../widgets/animated_popup.dart';
import '../../widgets/navigation_arrow_icon.dart';
import '../../widgets/work_list_sheet.dart';
import 'tool_setup_tab.dart';

import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
/// Paddock editor sub-state while [_MapScreenState._editorMode] is true.
enum EditorTool { browse, drawOuter, drawHole, edit }



enum RotationMode { northUp, travelUp, free }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  bool _editorMode = false;
  final MapController _mapController = MapController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _mapReady = false;

  // Raw GPS
  LatLng? _currentPos;
  double? _currentHeadingDeg; // 0..360

  // Display state (may lag raw GPS when smoothing is enabled)
  LatLng? _dispPos;
  double? _dispHeadingDeg;

  final GpsDisplaySmoother _gpsSmoother = GpsDisplaySmoother();
  Ticker? _gpsSmoothTicker;
  double _gpsSmoothness = 0.0;
  final ValueNotifier<LatLng?> _dispPosNotifier = ValueNotifier(null);
  final ValueNotifier<double?> _dispHeadingNotifier = ValueNotifier(null);
  final ValueNotifier<Polyline?> _lookAheadNotifier = ValueNotifier(null);

  final GpsInputController _gpsInput = GpsInputController();
  StreamSubscription<GpsFix>? _posSub;

  // rotation / camera
  RotationMode _rotationMode = RotationMode.northUp;
  bool _followGps = true;

  // settings
  String _units = "meters";
  ToolSetupDimensions _toolDims = const ToolSetupDimensions();
  List<ToolPreset> _toolPresets = [];
  String? _selectedToolPresetName;
  bool _satellite = false;
  TileProvider? _mapTileProvider;

  static const Color _overlayColor = Colors.green;
  static const double _overlayOpacity = 0.20;
  static const Color _guidanceColor = Colors.white;
  static const Color _headingColor = Colors.blueAccent;
  static const double _headingLengthM = 12.0;
  static const double _headingWidth = 3.5;
  static const bool _headingDashed = false;
  static const Color _swathColor = Colors.lightGreenAccent;
  static const double _swathOpacity = 0.55;

  double get _width => _toolDims.width;
  double get _offset => _toolDims.boomLateralOffset;

  final ImplementTracker _implementTracker = ImplementTracker();
  final ValueNotifier<List<Polyline>> _implementPolysNotifier = ValueNotifier([]);

  // paddocks
  List<Paddock> _paddocks = [];
  final ValueNotifier<List<Polygon>> _paddockPolysNotifier = ValueNotifier([]);
  final ValueNotifier<List<Marker>> _paddockLabelsNotifier = ValueNotifier([]);
  bool _paddockLabelsZoomVisible = false;
  bool _jobFinishInProgress = false;
  int _historyListGeneration = 0;
  Future<List<JobFileSummary>>? _jobSummariesFuture;
  Future<List<BackupInfo>>? _backupsFuture;

  /// Open product load (null if none).
  LoadSession? _openLoadSession;
  /// Closed-session rate/amount by job id for history.
  Map<String, JobProductStats> _productStatsByJobId = {};
  /// Suggested travel speed from recent actual vs target rate (km/h).
  double? _suggestedTargetSpeedKph;
  /// Optional scale reading on the job-complete panel.
  TextEditingController? _completedReadingCtrl;
  /// Planned paddocks + rate for the current run.
  PaddockWorkList _workList = PaddockWorkList();
  /// Tap paddocks to add/remove them from [_workList].
  bool _workListPicking = false;

  // selection
  final Set<int> _selectedIdx = <int>{};
  /// Paddocks the current job started in. Stays fixed until the job ends.
  final Set<int> _jobLockedPaddockIdx = <int>{};
  bool _suppressAutoPaddockSelect = false;
  int? _lastGpsInsidePaddockIdx;
  int _lastAutoSelectMs = 0;
  static const int _autoSelectIntervalMs = 500;

  // nav
  bool _navMode = false;
  static const _pipChannel = MethodChannel('pasturepath/pip');
  bool _inPipMode = false;
  LatLng? _pointA;
  LatLng? _pointB;
  /// Parallel guidance lines — each entry is one swath line (may be clipped to segments).
  List<List<List<LatLng>>> _guidanceParallelLines = [];
  int _activeLineIndex = 0; // index into [_guidanceParallelLines]
  static const double _guidanceSafetyFactor = 2.0;
  static const double _guidanceMaxSpanCapM = 500.0;
  static const double _guidanceAlongTrackMargin = 1.5;
  static const int _navLogicIntervalMs = 200;
  static const double _cameraMoveThresholdM = 0.35;
  static const double _cameraRotateThresholdDeg = 1.0;
  static const int _guidanceScanRadius = 3;
  int _lastNavLogicMs = 0;
  /// Desired follow aim (GPS). Separate from camera center so chase can finish.
  LatLng? _lastCameraTarget;
  double? _lastCameraRotationDeg;
  AnimationController? _cameraSwoopCtrl;
  static const Duration _cameraSwoopDuration = Duration(milliseconds: 480);
  /// Soft chase factor per GPS smooth tick (~follow / travel-up).
  static const double _cameraChaseAlpha = 0.28;
  /// Jump farther than this → swoop instead of soft chase (startup / recenter).
  static const double _cameraSwoopDistanceM = 40.0;
  /// Keep chasing until camera is this close to the aim point.
  static const double _cameraChaseSettleM = 0.2;

  // look-ahead line (nav mode)

  // persistence
  String? _persistedJsonPath;

  // recording path & swath
  DateTime? _jobStartTime;
  List<LatLng> _gpsRecordPath = [];
  List<LatLng> _jobPath = []; // boom-centre path derived from GPS
  double? _lastTravelBearingDeg;
  double _speedDistanceM = 0.0; // ∫ GPS speed dt (metres)
  DateTime? _lastSpeedFixTime;
  double _currentSpeedKph = 0.0;
  /// Cached coverage path length (same basis as job save).
  double _coverageDistanceCacheM = 0.0;
  int _coverageDistanceCacheMs = 0;
  int _coverageDistanceCachePathLen = -1;
  final List<Polygon> _committedSwathPolys = [];
  final ValueNotifier<List<Polygon>> _swathCommittedNotifier = ValueNotifier([]);
  final ValueNotifier<Polygon?> _swathLiveNotifier = ValueNotifier(null);
  final ValueNotifier<Polyline?> _navPathCommittedNotifier = ValueNotifier(null);
  final ValueNotifier<Polyline?> _navPathTailNotifier = ValueNotifier(null);
  final ValueNotifier<List<Polyline>> _navLinesNotifier = ValueNotifier([]);
  final ValueNotifier<double> _signedErrorNotifier = ValueNotifier(0.0);
  final ValueNotifier<int> _navHudTickNotifier = ValueNotifier(0);
  /// Boom points already polygonised into [_committedSwathPolys].
  int _swathCommittedBoomLen = 0;
  int _lastSwathCommitMs = 0;
  /// USB NMEA emits RMC+GGA(+GLL) per epoch — only sample once per ~25 Hz slot.
  int? _lastSwathRecordBucket;
  int? _lastSpeedSampleBucket;
  static const int _navSampleBucketMs = 40;
  static const double _minGpsRecordM = 0.45;
  static const double _maxGpsJumpM = 35.0;
  /// Stronger simplify on save keeps job files smaller for history / map show.
  static const double _jobSaveSimplifyMinDistM = 1.25;
  /// Display rebuild: keep continuous rings (no chunk seams). Throttle for lag.
  static const double _swathDisplaySimplifyMinDistM = 0.55;
  static const int _swathCommitIntervalMs = 400;
  static const double _swathCommitMinAdvanceM = 2.0;
  // ====== Paddock Editor ======
  EditorTool _tool = EditorTool.browse;
  /// Multi-select paddocks for delete (browse mode).
  bool _editorSelecting = false;

  /// Outer ring while creating a new paddock.
  final List<LatLng> _tempOuter = [];
  /// Hole ring while drawing a hole on [_editingIdx].
  final List<LatLng> _tempHole = [];
  /// Name chosen when starting a new paddock (+).
  String? _draftPaddockName;

  /// Paddock index being edited.
  int? _editingIdx;
  /// Selected vertex index (outer or hole).
  int? _selectedVertexIdx;
  /// Null = outer ring; otherwise hole index in [_editingIdx].
  int? _selectedHoleIdx;
  /// Selected vertex sticks to map center while panning.
  bool _vertexLiveMove = false;
  /// Ignore live-move while programmatically centering on a vertex.
  bool _suppressVertexLiveMove = false;

  void _clearVertexSelection({bool persist = false}) {
    if (persist &&
        _vertexLiveMove &&
        _editingIdx != null &&
        _selectedVertexIdx != null) {
      _persistFarmJson(_buildFarmGeoJsonBytes());
    }
    _selectedVertexIdx = null;
    _selectedHoleIdx = null;
    _vertexLiveMove = false;
    _suppressVertexLiveMove = false;
  }

  void _undoLastPoint() {
    if (_tool == EditorTool.drawOuter && _tempOuter.isNotEmpty) {
      setState(() => _tempOuter.removeLast());
    } else if (_tool == EditorTool.drawHole && _tempHole.isNotEmpty) {
      setState(() => _tempHole.removeLast());
    }
  }

  LatLng _mapCenterLatLng() => _mapController.camera.center;

  void _enterEditorMode() {
    setState(() {
      _editorMode = true;
      _editorSelecting = false;
      _tool = EditorTool.browse;
      _tempOuter.clear();
      _tempHole.clear();
      _draftPaddockName = null;
      _editingIdx = null;
      _clearVertexSelection();
      _selectedIdx.clear();
      _jobLockedPaddockIdx.clear();
      _navMode = false;
      _workListPicking = false;
      _followGps = false;
      if (_showingHistory) {
        _showingHistory = false;
        _activeHistoryJobs = [];
        _historySwathPolys.clear();
        _historyPathPolylines.clear();
      }
    });
    _rebuildPaddockLayers();
  }

  void _exitEditorMode() {
    if (_vertexLiveMove) {
      _persistFarmJson(_buildFarmGeoJsonBytes());
    }
    setState(() {
      _editorMode = false;
      _editorSelecting = false;
      _tool = EditorTool.browse;
      _tempOuter.clear();
      _tempHole.clear();
      _draftPaddockName = null;
      _editingIdx = null;
      _clearVertexSelection();
      _selectedIdx.clear();
    });
    _rebuildPaddockLayers();
  }

  /// Done: edit/draw → browse; selecting → cancel select; browse → exit editor.
  void _editorDone() {
    if (!_editorMode) return;
    if (_editorSelecting) {
      setState(() {
        _editorSelecting = false;
        _selectedIdx.clear();
      });
      _rebuildPaddockLayers();
      return;
    }
    if (_tool == EditorTool.browse) {
      _exitEditorMode();
      return;
    }
    if (_vertexLiveMove) {
      _persistFarmJson(_buildFarmGeoJsonBytes());
    }
    if (_tool == EditorTool.drawHole) {
      setState(() {
        _tool = EditorTool.edit;
        _tempHole.clear();
        _clearVertexSelection();
      });
      _rebuildPaddockLayers();
      return;
    }
    setState(() {
      _tool = EditorTool.browse;
      _tempOuter.clear();
      _tempHole.clear();
      _draftPaddockName = null;
      _editingIdx = null;
      _clearVertexSelection();
    });
    _rebuildPaddockLayers();
  }

  void _editorBeginSelect(int idx) {
    setState(() {
      _editorSelecting = true;
      _tool = EditorTool.browse;
      _editingIdx = null;
      _clearVertexSelection();
      _tempOuter.clear();
      _tempHole.clear();
      _draftPaddockName = null;
      _selectedIdx
        ..clear()
        ..add(idx);
    });
    _rebuildPaddockLayers();
  }

  void _editorToggleSelect(int idx) {
    setState(() {
      if (_selectedIdx.contains(idx)) {
        _selectedIdx.remove(idx);
      } else {
        _selectedIdx.add(idx);
      }
      if (_selectedIdx.isEmpty) {
        _editorSelecting = false;
      }
    });
    _rebuildPaddockLayers();
  }

  void _editorSelectAll() {
    setState(() {
      _editorSelecting = true;
      _selectedIdx
        ..clear()
        ..addAll(List.generate(_paddocks.length, (i) => i));
    });
    _rebuildPaddockLayers();
  }

  Future<void> _deleteSelectedPaddocks() async {
    if (_selectedIdx.isEmpty || !mounted) return;
    final count = _selectedIdx.length;
    final names = _selectedIdx.map((i) => _paddocks[i].name).toList()..sort();
    final label = names.length <= 3
        ? names.join(', ')
        : '${names.take(3).join(', ')} +${names.length - 3} more';
    final ok = await showFadeDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(count == 1 ? 'Delete paddock?' : 'Delete $count paddocks?'),
        content: Text(
          count == 1
              ? 'Delete “${names.first}” permanently from the farm map?'
              : 'Delete $count paddocks permanently?\n\n$label',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final remove = _selectedIdx.toList()..sort((a, b) => b.compareTo(a));
    setState(() {
      for (final i in remove) {
        if (i >= 0 && i < _paddocks.length) _paddocks.removeAt(i);
      }
      _selectedIdx.clear();
      _editorSelecting = false;
      _editingIdx = null;
      _clearVertexSelection();
    });
    _workList.removeNames(names);
    await _persistWorkList();
    await _persistFarmJson(_buildFarmGeoJsonBytes());
    if (_paddocks.isEmpty) {
      final p = await SharedPreferences.getInstance();
      await p.remove('farmJsonPath');
      _persistedJsonPath = null;
    }
    _rebuildPaddockLayers();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 1 ? 'Paddock deleted' : '$count paddocks deleted',
        ),
      ),
    );
  }

  Future<void> _startNewPaddock() async {
    if (!_editorMode) return;
    final name = await _promptName(context);
    if (name == null || name.isEmpty) return;
    setState(() {
      _tool = EditorTool.drawOuter;
      _draftPaddockName = name;
      _tempOuter.clear();
      _tempHole.clear();
      _editingIdx = null;
      _clearVertexSelection();
      _selectedIdx.clear();
    });
    _rebuildPaddockLayers();
  }

  void _startDrawHole() {
    if (!_editorMode || _editingIdx == null) return;
    if (_vertexLiveMove) {
      _persistFarmJson(_buildFarmGeoJsonBytes());
    }
    setState(() {
      _tool = EditorTool.drawHole;
      _tempHole.clear();
      _clearVertexSelection();
    });
  }

  void _selectPaddockForEdit(int idx) {
    if (_vertexLiveMove) {
      _persistFarmJson(_buildFarmGeoJsonBytes());
    }
    setState(() {
      _editorSelecting = false;
      _tool = EditorTool.edit;
      _editingIdx = idx;
      _clearVertexSelection();
      _tempOuter.clear();
      _tempHole.clear();
      _draftPaddockName = null;
      _selectedIdx
        ..clear()
        ..add(idx);
    });
    _rebuildPaddockLayers();
  }

  List<LatLng>? _selectedRing() {
    if (_editingIdx == null || _selectedVertexIdx == null) return null;
    final p = _paddocks[_editingIdx!];
    if (_selectedHoleIdx == null) return p.outer;
    if (_selectedHoleIdx! < 0 || _selectedHoleIdx! >= p.holes.length) {
      return null;
    }
    return p.holes[_selectedHoleIdx!];
  }

  void _selectVertex({required int? holeIdx, required int vertexIdx}) {
    if (!_editorMode ||
        _tool != EditorTool.edit ||
        _editingIdx == null ||
        !_mapReady) {
      return;
    }
    if (_vertexLiveMove &&
        (_selectedHoleIdx != holeIdx || _selectedVertexIdx != vertexIdx)) {
      _persistFarmJson(_buildFarmGeoJsonBytes());
    }
    final p = _paddocks[_editingIdx!];
    final ring = holeIdx == null ? p.outer : p.holes[holeIdx];
    if (vertexIdx < 0 || vertexIdx >= ring.length) return;

    setState(() {
      _selectedHoleIdx = holeIdx;
      _selectedVertexIdx = vertexIdx;
      _vertexLiveMove = true;
      _suppressVertexLiveMove = true;
    });

    final target = ring[vertexIdx];
    _swoopCamera(center: target);
    _runAfterMapFrame(() {
      if (!mounted) return;
      _suppressVertexLiveMove = false;
      _snapSelectedVertexToCenter(persist: false);
    });
  }

  void _snapSelectedVertexToCenter({required bool persist}) {
    if (!_editorMode ||
        !_vertexLiveMove ||
        _editingIdx == null ||
        _selectedVertexIdx == null) {
      return;
    }
    final ring = _selectedRing();
    if (ring == null) return;
    final i = _selectedVertexIdx!;
    if (i < 0 || i >= ring.length) return;
    final center = _mapCenterLatLng();
    ring[i] = center;
    _recalcPaddock(_editingIdx!);
    if (persist) {
      _persistFarmJson(_buildFarmGeoJsonBytes());
    }
    if (mounted) setState(() {});
  }

  void _addVertexAtCrosshair() {
    if (!_editorMode || !_mapReady) return;
    final ll = _mapCenterLatLng();
    if (_tool == EditorTool.drawOuter) {
      setState(() => _tempOuter.add(ll));
      return;
    }
    if (_tool == EditorTool.drawHole) {
      setState(() => _tempHole.add(ll));
      return;
    }
    if (_tool == EditorTool.edit && _editingIdx != null) {
      if (_vertexLiveMove) {
        _persistFarmJson(_buildFarmGeoJsonBytes());
      }
      // Insert on the ring currently focused (selected hole, else outer).
      final p = _paddocks[_editingIdx!];
      final holeIdx = _selectedHoleIdx;
      final ring = holeIdx == null ? p.outer : p.holes[holeIdx];
      late final int insertAt;
      if (ring.length < 2) {
        insertAt = ring.length;
        ring.add(ll);
      } else {
        insertAt = _nearestEdgeInsertIndex(ring, ll);
        ring.insert(insertAt, ll);
      }
      _recalcPaddock(_editingIdx!);
      _persistFarmJson(_buildFarmGeoJsonBytes());
      _selectVertex(holeIdx: holeIdx, vertexIdx: insertAt);
    }
  }

  void _deleteSelectedVertex() {
    if (!_editorMode ||
        _tool != EditorTool.edit ||
        _editingIdx == null ||
        _selectedVertexIdx == null) {
      return;
    }
    final ring = _selectedRing();
    if (ring == null) return;

    // Last vertices of a hole → remove the whole hole (can't shrink below 3).
    if (_selectedHoleIdx != null && ring.length <= 3) {
      _deleteSelectedHole();
      return;
    }

    if (ring.length <= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A paddock needs at least 3 vertices')),
      );
      return;
    }
    final i = _selectedVertexIdx!;
    if (i < 0 || i >= ring.length) return;
    setState(() {
      ring.removeAt(i);
      _clearVertexSelection();
    });
    _recalcPaddock(_editingIdx!);
    _persistFarmJson(_buildFarmGeoJsonBytes());
  }

  void _deleteSelectedHole() {
    if (!_editorMode ||
        _tool != EditorTool.edit ||
        _editingIdx == null ||
        _selectedHoleIdx == null) {
      return;
    }
    final idx = _editingIdx!;
    final holeIdx = _selectedHoleIdx!;
    final holes = _paddocks[idx].holes;
    if (holeIdx < 0 || holeIdx >= holes.length) return;
    setState(() {
      holes.removeAt(holeIdx);
      _clearVertexSelection();
    });
    _recalcPaddock(idx);
    _persistFarmJson(_buildFarmGeoJsonBytes());
  }

  /// Index in [ring] at which to insert [p] (on the nearest edge).
  int _nearestEdgeInsertIndex(List<LatLng> ring, LatLng p) {
    if (ring.length < 2) return ring.length;
    const dist = Distance();
    var bestD = double.infinity;
    var bestInsert = 1;
    for (var i = 0; i < ring.length; i++) {
      final a = ring[i];
      final b = ring[(i + 1) % ring.length];
      final d = _distancePointToSegmentM(dist, p, a, b);
      if (d < bestD) {
        bestD = d;
        bestInsert = i + 1;
      }
    }
    return bestInsert > ring.length ? ring.length : bestInsert;
  }

  double _distancePointToSegmentM(
    Distance dist,
    LatLng p,
    LatLng a,
    LatLng b,
  ) {
    final ab = dist.as(LengthUnit.Meter, a, b);
    if (ab < 1e-3) return dist.as(LengthUnit.Meter, p, a);
    // Local ENU projection around a for a stable segment distance.
    final lat0 = a.latitude * math.pi / 180.0;
    final mPerDegLat = 111320.0;
    final mPerDegLon = 111320.0 * math.cos(lat0);
    double x(LatLng q) => (q.longitude - a.longitude) * mPerDegLon;
    double y(LatLng q) => (q.latitude - a.latitude) * mPerDegLat;
    final ax = 0.0, ay = 0.0;
    final bx = x(b), by = y(b);
    final px = x(p), py = y(p);
    final abx = bx - ax, aby = by - ay;
    final t = ((px - ax) * abx + (py - ay) * aby) / (abx * abx + aby * aby);
    final tc = t.clamp(0.0, 1.0);
    final cx = ax + abx * tc, cy = ay + aby * tc;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }


  // history view
  bool _showingHistory = false;
  List<SavedJob> _activeHistoryJobs = [];
  SavedJob? _completedJobSummary;
  final List<Polygon> _historySwathPolys = [];
  final List<Polyline> _historyPathPolylines = [];

  // history multi-select in tab
  bool _histSelecting = false;
  final Set<String> _histSelected = <String>{};
  final Set<DateTime> _histExpandedDays = <DateTime>{};

  // Error HUD / chevrons (+ve steer right, -ve steer left via [_signedErrorNotifier])
  late final AnimationController _chevCtrl;
  late final TabController _drawerTabCtrl;
  static const int _chevrons = 4; // avoids overflow; auto-sizes

  @override
  void initState() {
    super.initState();
    _gpsInput.addListener(_onGpsInputChanged);

    _pipChannel.setMethodCallHandler((call) async {
      if (call.method == 'pipModeChanged') {
        final args = call.arguments as Map;
        final inPip = args['inPip'] as bool;
        if (mounted) setState(() => _inPipMode = inPip);
      }
    });
    // Smooth pulsing animation for chevrons
    _chevCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();

    _drawerTabCtrl = TabController(length: 3, vsync: this);

    _gpsSmoothTicker = createTicker(_onGpsSmoothTick);

    WidgetsBinding.instance.addPostFrameCallback((_) => _runStartupInit());
  }

  int _startupSizeRetries = 0;

  Future<void> _runStartupInit() async {
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    if ((size.width < 1 || size.height < 1) && _startupSizeRetries < 40) {
      _startupSizeRetries++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _runStartupInit());
      return;
    }
    try {
      await _loadPrefs();
      if (!mounted) return;
      _toolPresets = await ToolPresetStore.list();
      if (_selectedToolPresetName != null) {
        final ok = _toolPresets.any(
          (e) => e.name.toLowerCase() == _selectedToolPresetName!.toLowerCase(),
        );
        if (!ok) _selectedToolPresetName = null;
      }
      final tileProvider = await MapTileCache.provider();
      if (mounted) {
        setState(() => _mapTileProvider = tileProvider);
      }
      await _loadPersistedFarmJsonIfAny();
      await _refreshLoadSessionState();
      await _loadWorkList();
      if (!mounted) return;
      await _ensureLocationFlow();
    } catch (e, st) {
      debugPrint('Startup init failed: $e\n$st');
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _gpsInput.dispose();
    _gpsSmoothTicker?.dispose();
    _dispPosNotifier.dispose();
    _dispHeadingNotifier.dispose();
    _lookAheadNotifier.dispose();
    _implementPolysNotifier.dispose();
    _swathCommittedNotifier.dispose();
    _swathLiveNotifier.dispose();
    _navPathCommittedNotifier.dispose();
    _navPathTailNotifier.dispose();
    _navLinesNotifier.dispose();
    _signedErrorNotifier.dispose();
    _navHudTickNotifier.dispose();
    _paddockPolysNotifier.dispose();
    _paddockLabelsNotifier.dispose();
    _cameraSwoopCtrl?.dispose();
    _completedReadingCtrl?.dispose();
    _chevCtrl.dispose();
    _drawerTabCtrl.dispose();
    _inPipMode = false;
    _gpsInput.removeListener(_onGpsInputChanged);
    WakelockPlus.disable();
    _setPipEnabled(false);
    super.dispose();
  }

  // ---------- Prefs ----------
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final gpsMode = GpsInputModeX.fromPrefs(p.getString('gpsInputMode'));
    setState(() {
      _units = p.getString('units') ?? 'meters';
      _toolDims = ToolSetupDimensions(
        width: p.getDouble('width') ?? 3.0,
        boomLateralOffset: p.getDouble('boomLateralOffset') ?? p.getDouble('offset') ?? 0.0,
        gpsLateralOffset: p.getDouble('gpsLateralOffset') ?? 0.0,
        hitchToAxle: p.getDouble('hitchToAxle') ?? p.getDouble('drawbarLength') ?? 3.0,
      );
      _satellite = p.getBool('satellite') ?? false;
      _gpsSmoothness = p.getDouble('gpsSmoothness') ?? 0.0;
      _gpsSmoother.smoothness = _gpsSmoothness;
      if (_gpsSmoothness > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureGpsSmoothTickerRunning());
      }
      final presetName = p.getString('selectedToolPresetName');
      _selectedToolPresetName =
          (presetName != null && presetName.isNotEmpty) ? presetName : null;
    });
    await _gpsInput.setMode(gpsMode);
  }

  Future<void> _loadWorkList() async {
    try {
      final list = await PaddockWorkListStore.load();
      if (!mounted) return;
      if (_paddocks.isNotEmpty) {
        list.pruneMissing(_paddocks.map((p) => p.name));
      }
      setState(() => _workList = list);
      _rebuildPaddockLayers();
    } catch (e) {
      debugPrint('Work list load failed: $e');
    }
  }

  Future<void> _persistWorkList() async {
    await PaddockWorkListStore.save(_workList);
  }

  void _pruneWorkListToFarm() {
    if (_workList.isEmpty || _paddocks.isEmpty) return;
    final before = _workList.paddockCount;
    _workList.pruneMissing(_paddocks.map((p) => p.name));
    if (_workList.paddockCount != before) {
      _persistWorkList();
    }
  }

  Future<void> _writePrefsToDisk() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('units', _units);
    await p.setDouble('width', _toolDims.width);
    await p.setDouble('offset', _toolDims.boomLateralOffset);
    await p.setDouble('boomLateralOffset', _toolDims.boomLateralOffset);
    await p.setDouble('gpsLateralOffset', _toolDims.gpsLateralOffset);
    await p.setDouble('hitchToAxle', _toolDims.hitchToAxle);
    await p.setDouble('drawbarLength', _toolDims.hitchToAxle);
    await p.setBool('satellite', _satellite);
    await p.setString(ThemeController.prefsKey, ThemeController.toPrefs(widget.themeController.mode));
    await p.setDouble('gpsSmoothness', _gpsSmoothness);
    await p.setString('gpsInputMode', _gpsInput.mode.prefsValue);
    if (_selectedToolPresetName != null && _selectedToolPresetName!.isNotEmpty) {
      await p.setString('selectedToolPresetName', _selectedToolPresetName!);
    } else {
      await p.remove('selectedToolPresetName');
    }
  }

  Map<String, dynamic> _currentSettingsMap() => {
    'units': _units,
    'width': _toolDims.width,
    'offset': _toolDims.boomLateralOffset,
    'boomLateralOffset': _toolDims.boomLateralOffset,
    'gpsLateralOffset': _toolDims.gpsLateralOffset,
    'hitchToAxle': _toolDims.hitchToAxle,
    'drawbarLength': _toolDims.hitchToAxle,
    'satellite': _satellite,
    ThemeController.prefsKey: ThemeController.toPrefs(widget.themeController.mode),
    'gpsSmoothness': _gpsSmoothness,
    'gpsInputMode': _gpsInput.mode.prefsValue,
    if (_selectedToolPresetName != null) 'selectedToolPresetName': _selectedToolPresetName,
  };

  Future<String?> _farmJsonTextForBackup() async {
    if (_paddocks.isNotEmpty) {
      return utf8.decode(_buildFarmGeoJsonBytes());
    }
    final path = _persistedJsonPath;
    if (path != null) {
      final f = io.File(path);
      if (await f.exists()) return await f.readAsString();
    }
    final fallback = io.File('${await _docsPath()}/farm.json');
    if (await fallback.exists()) return await fallback.readAsString();
    return null;
  }

  Future<void> _createBackup() async {
    try {
      if (_paddocks.isNotEmpty) {
        await _persistFarmJson(_buildFarmGeoJsonBytes());
      }
      await _writePrefsToDisk();
      final result = await BackupStore.createBackup(
        settings: _currentSettingsMap(),
        farmJsonText: await _farmJsonTextForBackup(),
      );
      _invalidateBackupsFuture();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.userMessage)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup failed: $e')),
      );
    }
  }

  Future<void> _restoreBackup() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      dialogTitle: 'Select a PasturePath backup',
    );
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    final bytes = f.bytes ?? (f.path != null ? await io.File(f.path!).readAsBytes() : null);
    if (bytes == null) return;

    Map<String, dynamic> preview;
    try {
      preview = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (preview['format'] != 'pasturepath-backup') {
        throw FormatException('Not a PasturePath backup');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid backup file: $e')),
      );
      return;
    }

    final jobs = (preview['jobs'] as List?)?.length ?? 0;
    final hasFarm = preview['farmJson'] != null;
    final created = preview['createdAt']?.toString() ?? 'unknown date';

    if (!mounted) return;
    final ok = await showFadeDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
          'This will replace your current jobs, farm map, and settings with the backup from $created.\n\n'
          'Jobs: $jobs\n'
          'Farm map: ${hasFarm ? 'included' : 'none'}\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;

    io.File? tempFile;
    try {
      if (f.path != null) {
        await BackupStore.restoreBackup(f.path!);
      } else {
        final dir = await BackupStore.backupsDir();
        tempFile = io.File('$dir/_restore-temp.json');
        await tempFile.writeAsBytes(bytes, flush: true);
        await BackupStore.restoreBackup(tempFile.path);
      }
      await _applyRestoredData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup restored')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
    } finally {
      if (tempFile != null && await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  Future<void> _applyRestoredData() async {
    await _loadPrefs();
    await widget.themeController.load();
    _invalidateBackupsFuture();
    setState(() {
      _paddocks = [];
      _persistedJsonPath = null;
      _navMode = false;
      _showingHistory = false;
      _activeHistoryJobs = [];
      _completedJobSummary = null;
      _historySwathPolys.clear();
      _historyPathPolylines.clear();
      _selectedIdx.clear();
      _jobLockedPaddockIdx.clear();
      _navLinesNotifier.value = [];
      _guidanceParallelLines = [];
      _pointA = null;
      _pointB = null;
      _lookAheadNotifier.value = null;
      _clearSwathDisplay();
      _histSelecting = false;
      _histSelected.clear();
      _suppressAutoPaddockSelect = false;
    });
    _rebuildPaddockLayers();
    await _loadPersistedFarmJsonIfAny();
    await _refreshLoadSessionState();
    _resetToMapDefaults();
  }

  Future<void> _refreshLoadSessionState() async {
    final open = await LoadSessionStore.openSession();
    final stats = await LoadSessionStore.productStatsByJobId();
    if (!mounted) return;
    setState(() {
      _openLoadSession = open;
      _productStatsByJobId = stats;
    });
  }

  Future<void> _openProductLoadSheet() async {
    await _refreshLoadSessionState();
    if (!mounted) return;
    final open = _openLoadSession;
    if (open == null) {
      await _showStartLoadDialog();
    } else {
      await _showOpenLoadDialog(open);
    }
  }

  List<String> _selectedPaddockNames() => _selectedIdx
      .where((i) => i >= 0 && i < _paddocks.length)
      .map((i) => _paddocks[i].name)
      .toList();

  void _beginWorkListPicking() {
    setState(() {
      _workListPicking = true;
      _suppressAutoPaddockSelect = true;
      _workList.addNames(_selectedPaddockNames());
    });
    _persistWorkList();
    _rebuildPaddockLayers();
  }

  void _endWorkListPicking({bool openSheet = false}) {
    setState(() => _workListPicking = false);
    if (openSheet && _workList.isNotEmpty) {
      _showWorkListDialog();
    }
  }

  void _toggleWorkListPaddockAt(int idx) {
    if (idx < 0 || idx >= _paddocks.length) return;
    final name = _paddocks[idx].name;
    setState(() {
      if (_workList.contains(name)) {
        _workList.removeName(name);
      } else {
        _workList.addNames([name]);
      }
      _selectedIdx
        ..clear()
        ..add(idx);
      _suppressAutoPaddockSelect = true;
    });
    _persistWorkList();
    _rebuildPaddockLayers();
  }

  Future<void> _onAddListPressed() async {
    if (_workListPicking) {
      _endWorkListPicking(openSheet: _workList.targetRatePerHa == null);
      return;
    }
    _beginWorkListPicking();
  }

  Future<void> _markWorkListJobsComplete(Iterable<String> jobPaddockNames) async {
    if (_workList.isEmpty) return;
    final before = _workList.completedCount;
    setState(() => _workList.markCompleted(jobPaddockNames));
    if (_workList.completedCount == before) return;
    await _persistWorkList();
    _rebuildPaddockLayers();
  }

  Future<void> _clearWorkList({bool confirm = true}) async {
    if (_workList.isEmpty) return;
    if (confirm) {
      final ok = await showFadeDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete paddock list?'),
          content: const Text(
            'Removes the planned paddocks and progress. This does not delete jobs.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep list'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete list'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      _workList.clear();
      _workListPicking = false;
    });
    await _persistWorkList();
    _rebuildPaddockLayers();
  }

  Future<void> _showWorkListDialog() async {
    if (!mounted) return;
    final last = await LastLoadPrefs.load();
    if (!mounted) return;
    final result = await showWorkListSheet(
      context: context,
      list: _workList,
      paddocks: _paddocks,
      areaText: _areaText,
      hintProductName: last?.productName,
      hintRate: last?.primaryRatePerHa.toStringAsFixed(0),
      hintUnit: last?.unit,
      onRemovePaddock: (name) {
        _workList.removeName(name);
        _rebuildPaddockLayers();
        _persistWorkList();
      },
    );
    if (!mounted) return;
    if (result == null) {
      await _persistWorkList();
      if (mounted) setState(() {});
      return;
    }
    if (result.delete) {
      await _clearWorkList();
      return;
    }
    _workList.unit = result.unit;
    _workList.productName = result.productName?.trim().isEmpty == true
        ? null
        : result.productName?.trim();
    if (result.rate != null && result.rate! > 0) {
      _workList.targetRatePerHa = result.rate;
    }
    await _persistWorkList();
    if (mounted) setState(() {});
  }

  Widget _workListHudChip() {
    if (_workList.isEmpty && !_workListPicking) return const SizedBox.shrink();
    final totalHa = _workList.totalHa(_paddocks);
    final doneHa = _workList.completedHa(_paddocks);
    final scheme = Theme.of(context).colorScheme;
    final rate = _workList.targetRatePerHa;
    return Material(
      elevation: _fabElevation,
      color: _fabFill,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _showWorkListDialog,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_compactArea(doneHa)}/${_compactArea(totalHa)} ${_units == 'feet' ? 'ac' : 'ha'}'
                '  ${_workList.completedCount}/${_workList.paddockCount} paddocks',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: scheme.primary,
                ),
              ),
              if (rate != null && rate > 0)
                Text(
                  '${_workList.displayName}  ${rate.toStringAsFixed(0)} ${_workList.rateUnitLabel}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface.withOpacity(0.75),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _compactArea(double ha) {
    final v = _units == 'feet' ? ha * 2.47105 : ha;
    if ((v - v.roundToDouble()).abs() < 0.05) return v.round().toString();
    return v.toStringAsFixed(1);
  }

  Widget _workListPickingBar() {
    final scheme = Theme.of(context).colorScheme;
    final n = _workList.paddockCount;
    return Material(
      elevation: _fabElevation,
      color: _fabFill,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.touch_app, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Tap paddocks to add or remove',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: scheme.onSurface,
                    ),
                  ),
                  Text(
                    '$n paddock${n == 1 ? '' : 's'} · ${_areaText(_workList.totalHa(_paddocks))}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _endWorkListPicking(
                openSheet: _workList.isNotEmpty &&
                    _workList.targetRatePerHa == null,
              ),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showStartLoadDialog() async {
    final last = await LastLoadPrefs.load();
    if (!mounted) return;
    final nameFocus = FocusNode();
    final startFocus = FocusNode();
    final rateFocus = FocusNode();
    final productKgFocus = FocusNode();
    final nameCtrl = TextEditingController();
    final startCtrl = TextEditingController();
    final rateCtrl = TextEditingController();
    final productKgCtrl = TextEditingController();
    var unit = last?.unit ?? 'kg';
    final ok = await showFadeDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final typedKg = double.tryParse(productKgCtrl.text.trim());
            final dissolved = unit == 'L' &&
                ((typedKg != null && typedKg > 0) ||
                    (productKgCtrl.text.trim().isEmpty &&
                        (last?.dissolved ?? false) &&
                        unit == (last?.unit ?? unit)));
            final hintName = last?.productName;
            final hintStart = last != null && last.unit == unit
                ? last.startQty.toStringAsFixed(0)
                : null;
            final hintProductKg = last != null &&
                    last.unit == 'L' &&
                    last.productLoadedKg != null
                ? last.productLoadedKg!.toStringAsFixed(0)
                : null;
            final hintRate = last != null && last.unit == unit
                ? last.primaryRatePerHa.toStringAsFixed(0)
                : null;
            return AlertDialog(
              title: const Text('Start Load'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (last != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Grey hints are your last load — Start to reuse, or tap a field to type new.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'kg', label: Text('kg')),
                        ButtonSegment(value: 'L', label: Text('L')),
                      ],
                      selected: {unit},
                      onSelectionChanged: (s) => setLocal(() => unit = s.first),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      focusNode: nameFocus,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => startFocus.requestFocus(),
                      decoration: InputDecoration(
                        labelText: 'Product name',
                        hintText: hintName ?? 'eg. Urea',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: startCtrl,
                      focusNode: startFocus,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) {
                        if (unit == 'L') {
                          productKgFocus.requestFocus();
                        } else {
                          rateFocus.requestFocus();
                        }
                      },
                      decoration: InputDecoration(
                        labelText: unit == 'L'
                            ? 'Start reading (L)'
                            : 'Start reading (kg)',
                        hintText: hintStart ?? 'eg. 2000',
                      ),
                    ),
                    if (unit == 'L') ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: productKgCtrl,
                        focusNode: productKgFocus,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        onChanged: (_) => setLocal(() {}),
                        onSubmitted: (_) => rateFocus.requestFocus(),
                        decoration: InputDecoration(
                          labelText: 'Product loaded (kg)',
                          hintText: hintProductKg ??
                              'eg. 300 — leave blank for spray only',
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextField(
                      controller: rateCtrl,
                      focusNode: rateFocus,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => Navigator.pop(ctx, true),
                      decoration: InputDecoration(
                        labelText: dissolved
                            ? 'Target product rate (kg/ha)'
                            : (unit == 'L'
                                ? 'Target spray rate (L/ha)'
                                : 'Target rate (kg/ha)'),
                        hintText: hintRate ??
                            (dissolved
                                ? 'eg. 35'
                                : (unit == 'L' ? 'eg. 100' : 'eg. 80')),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Start'),
                ),
              ],
            );
          },
        );
      },
    );
    nameFocus.dispose();
    startFocus.dispose();
    rateFocus.dispose();
    productKgFocus.dispose();
    nameCtrl.dispose();
    startCtrl.dispose();
    rateCtrl.dispose();
    productKgCtrl.dispose();
    if (ok != true || !mounted) return;

    String? pickStr(TextEditingController c, String? hint) {
      final t = c.text.trim();
      if (t.isNotEmpty) return t;
      return hint;
    }

    double? pickNum(TextEditingController c, double? hint) {
      final t = c.text.trim();
      if (t.isNotEmpty) return double.tryParse(t);
      return hint;
    }

    final sameUnit = last != null && last.unit == unit;
    final name = pickStr(nameCtrl, sameUnit ? last!.productName : null);
    final startQty = pickNum(startCtrl, sameUnit ? last!.startQty : null);
    final productKg = unit == 'L'
        ? pickNum(productKgCtrl, sameUnit ? last!.productLoadedKg : null)
        : null;
    final dissolved = unit == 'L' && productKg != null && productKg > 0;
    final rate = pickNum(
      rateCtrl,
      sameUnit ? last!.primaryRatePerHa : null,
    );

    if (startQty == null || startQty < 0 || rate == null || rate <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter valid start reading and target rate')),
      );
      return;
    }
    final double carrierRate;
    final double? productRate;
    if (dissolved) {
      productRate = rate;
      carrierRate = startQty * rate / productKg;
    } else {
      productRate = null;
      carrierRate = rate;
    }
    try {
      await LoadSessionStore.start(
        startQty: startQty,
        targetRatePerHa: carrierRate,
        unit: unit,
        productName: name,
        productLoadedKg: dissolved ? productKg : null,
        targetProductRatePerHa: productRate,
      );
      await LastLoadPrefs.save(
        unit: unit,
        startQty: startQty,
        targetRatePerHa: carrierRate,
        primaryRatePerHa: rate,
        productName: name,
        productLoadedKg: dissolved ? productKg : null,
        dissolved: dissolved,
      );
      await _refreshLoadSessionState();
      if (!mounted) return;
      final label = (name == null || name.isEmpty) ? unit : name;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            dissolved
                ? 'Load started · $label · ${rate.toStringAsFixed(0)} kg/ha'
                : 'Load started · $label · ${rate.toStringAsFixed(0)} $unit/ha',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start load: $e')),
      );
    }
  }

  Future<void> _showOpenLoadDialog(LoadSession open) async {
    final readingCtrl = TextEditingController(
      text: open.expectedQtyNow > 0
          ? open.expectedQtyNow.toStringAsFixed(0)
          : '',
    );
    final action = await showFadeDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(open.displayName),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Not now'),
            ),
          ],
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Start ${open.currentQty.toStringAsFixed(0)} ${open.unitLabel}'
                  ' · target ${open.primaryTargetRateLabel}',
                ),
                Text(
                  '${open.jobs.length} jobs · ${_areaText(open.totalAppliedHa)}'
                  ' · expect ${open.expectedQtyNow.toStringAsFixed(0)} ${open.unitLabel}',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: readingCtrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => Navigator.pop(ctx, 'record'),
                  decoration: InputDecoration(
                    labelText: 'Scale reading (${open.unitLabel})',
                    hintText: 'Current hopper / tank weight',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, 'record'),
                  icon: const Icon(Icons.scale),
                  label: const Text('Save reading'),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.pop(ctx, 'end'),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Save reading & end load'),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'cancel_load'),
                  child: const Text('End load using expected remaining'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (action == 'cancel_load') {
      final confirm = await showFadeDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('End load using expected remaining?'),
          content: Text(
            'Uses expected remaining '
            '(${open.expectedQtyNow.toStringAsFixed(0)} ${open.unitLabel}) '
            'for any jobs not yet weighed. Rates already recorded stay in history.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep load open'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('End load'),
            ),
          ],
        ),
      );
      if (confirm == true) {
        try {
          final closed = await LoadSessionStore.closeWithExpected();
          await _refreshLoadSessionState();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Load finished · expected remaining applied · '
                '${closed.jobs.where((j) => j.hasReading).length} jobs rated',
              ),
            ),
          );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not finish load: $e')),
          );
        }
      }
      return;
    }
    if (action != 'record' && action != 'end') return;
    final reading = double.tryParse(readingCtrl.text.trim());
    if (reading == null || reading < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid scale reading')),
      );
      return;
    }
    try {
      if (action == 'record') {
        final updated = await LoadSessionStore.recordReading(reading: reading);
        await _refreshLoadSessionState();
        _updateSuggestedSpeedFromSession(updated);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Reading saved · new start ${updated.currentQty.toStringAsFixed(0)} ${updated.unitLabel}',
            ),
          ),
        );
        return;
      }
      final closed = await LoadSessionStore.endLoad(endQty: reading);
      await _refreshLoadSessionState();
      _updateSuggestedSpeedFromSession(closed);
      if (!mounted) return;
      final primaryRate = closed.actualProductRatePerHa ?? closed.actualRatePerHa;
      final used = closed.usedQty;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            primaryRate == null || used == null
                ? 'Load ended'
                : 'Load ended · ${closed.displayName} '
                    '${primaryRate.toStringAsFixed(0)} '
                    '${closed.targetProductRatePerHa != null ? 'kg' : closed.unitLabel}/ha'
                    ' · ${_areaText(closed.totalAppliedHa)}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save reading: $e')),
      );
    }
  }

  // Reading prompts live on the job-complete panel (optional field), not a popup.

  void _updateSuggestedSpeedFromSession(LoadSession session) {
    // Prefer the most recent job that has a reading.
    LoadSessionJobRef? latest;
    for (final j in session.jobs.reversed) {
      if (j.hasReading && j.appliedHa > 0) {
        latest = j;
        break;
      }
    }
    if (latest == null) return;
    // Gate speed from actual application intensity (used / covered swath),
    // not the paddock-area rate used for records.
    final used = session.productAmountForJob(latest.jobId) ??
        session.amountForJob(latest.jobId);
    if (used == null || used <= 0 || latest.appliedHa <= 0) return;
    final actual = used / latest.appliedHa;
    final target = session.primaryTargetRatePerHa;
    if (actual <= 0 || target <= 0) return;

    final avgSpeed = _completedJobSummary?.avgSpeedKph ??
        _navLiveAvgSpeedKph();
    if (avgSpeed <= 0) return;

    final coverage = _completedJobSummary != null
        ? _jobCoveragePercent(_completedJobSummary!)
        : _navLiveCoveragePercent();

    // At fixed gate opening, applied rate ∝ 1/speed.
    var suggested = avgSpeed * (actual / target);
    if (coverage < 90) suggested *= 0.95;
    if (coverage > 115) suggested *= 1.05;
    suggested = suggested.clamp(1.0, 40.0);

    if (!mounted) return;
    setState(() => _suggestedTargetSpeedKph = suggested);
  }

  Future<void> _savePrefs() async {
    await _writePrefsToDisk();
  }


  // ---------- Build GeoJSON (FeatureCollection) from current paddocks ----------
  Uint8List _buildFarmGeoJsonBytes() {
    Map<String, dynamic> fc = {
      "type": "FeatureCollection",
      "features": _paddocks.map((pdk) {
        List<List<List<double>>> coords = [];
        // outer
        coords.add(pdk.outer.map((pt) => [pt.longitude, pt.latitude]).toList());
        // ensure closed ring
        if (coords[0].isNotEmpty && (coords[0].first[0] != coords[0].last[0] || coords[0].first[1] != coords[0].last[1])) {
          coords[0].add(List<double>.from(coords[0].first));
        }
        // holes
        for (final h in pdk.holes) {
          final ring = h.map((pt) => [pt.longitude, pt.latitude]).toList();
          if (ring.isNotEmpty && (ring.first[0] != ring.last[0] || ring.first[1] != ring.last[1])) {
            ring.add(List<double>.from(ring.first));
          }
          coords.add(ring);
        }
        return {
          "type": "Feature",
          "properties": {"Name": pdk.name, "Area,ha": pdk.areaHa},
          "geometry": {"type": "Polygon", "coordinates": coords}
        };
      }).toList()
    };
    final txt = jsonEncode(fc);
    return Uint8List.fromList(utf8.encode(txt));
  }
// ---------- File persistence ----------
  Future<String> _docsPath() async {
    final d = await getApplicationDocumentsDirectory();
    return d.path;
  }

  Future<void> _persistFarmJson(Uint8List bytes) async {
    final path = '${await _docsPath()}/farm.json';
    final f = io.File(path);
    await f.writeAsBytes(bytes, flush: true);
    final p = await SharedPreferences.getInstance();
    await p.setString('farmJsonPath', path);
    setState(() => _persistedJsonPath = path);
  }

  Future<void> _loadPersistedFarmJsonIfAny() async {
    final p = await SharedPreferences.getInstance();
    final path = p.getString('farmJsonPath');
    if (path == null) return;
    final f = io.File(path);
    if (!await f.exists()) return;
    final bytes = await f.readAsBytes();
    final parsed = GeoJsonParser.parseBytes(bytes);
    if (parsed.error == null) {
      setState(() {
        _paddocks = parsed.paddocks;
        _persistedJsonPath = path;
        _maybeAutoSelectPaddockFromGps();
      });
      _pruneWorkListToFarm();
      _rebuildPaddockLayers();
      if (_paddocks.isNotEmpty && _mapReady) {
        _mapController.move(_paddocks.first.labelPoint, 16);
      }
    }
  }

  // ---------- Location ----------
  Future<void> _ensureLocationFlow() async {
    _posSub?.cancel();
    _posSub = _gpsInput.fixes.listen((fix) {
      if (!mounted) return;
      _applyGpsFix(fix);
      _maybeDismissCompletedSummaryOnGpsLeave();
      // Pose updates go through notifiers — do not setState the whole map screen.
    });
    try {
      await _gpsInput.start();
    } catch (e) {
      debugPrint('GPS start failed: $e');
    }
    if (mounted && _gpsInput.lastError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_gpsInput.lastError!)),
      );
    }
  }

  void _applyGpsFix(GpsFix p, {bool snapDisplay = false}) {
    final prevPos = _currentPos;
    final newPos = LatLng(p.latitude, p.longitude);
    double? newHeading = p.headingDeg ?? _currentHeadingDeg;
    if (newHeading == null && prevPos != null) {
      final d = const Distance().as(LengthUnit.Meter, prevPos, newPos);
      if (d >= 0.4) {
        newHeading = const Distance().bearing(prevPos, newPos);
      }
    }

    _currentPos = newPos;
    _currentHeadingDeg = newHeading;
    if (p.hasSpeed) {
      _currentSpeedKph = p.speedMps! * 3.6;
    }
    _accumulateSpeedDistance(p);
    _lastSpeedFixTime = p.timestamp;

    _gpsSmoother.smoothness = _gpsSmoothness;
    _gpsSmoother.onFix(
      position: newPos,
      headingDeg: newHeading,
      snapDisplay: snapDisplay || _gpsSmoothness <= 0,
    );
    _syncDisplayFromSmoother();
    _updateImplementGeometry();
    _maybeRecordSwathFromGps(p);
    if (_navMode) {
      _syncLiveSwathTip();
      _syncNavPathTail();
      _updateLookAhead();
      _runNavLogicIfDue(force: true);
    }
    _maybeAutoSelectPaddockFromGps();
    _applyDisplayCamera();
    _notifyDisplayPosition();
    if (_navMode) _navHudTickNotifier.value++;

    if (_gpsSmoothness > 0) {
      _ensureGpsSmoothTickerRunning();
    }
  }

  bool _shouldRunNavLogic() {
    final ms = DateTime.now().millisecondsSinceEpoch;
    if (ms - _lastNavLogicMs < _navLogicIntervalMs) return false;
    _lastNavLogicMs = ms;
    return true;
  }

  void _runNavLogicIfDue({bool force = false}) {
    if (!force && !_shouldRunNavLogic()) return;
    _updateActiveGuidanceLine();
  }

  void _ensureGpsSmoothTickerRunning() {
    if (_gpsSmoothness <= 0 || _gpsSmoothTicker == null) return;
    if (!_gpsSmoothTicker!.isActive) _gpsSmoothTicker!.start();
  }

  void _syncDisplayFromSmoother() {
    _dispPos = _gpsSmoother.displayPosition;
    _dispHeadingDeg = _gpsSmoother.displayHeading;
  }

  void _notifyDisplayPosition() {
    _dispPosNotifier.value = _dispPos;
    _dispHeadingNotifier.value = _tractorHeadingDeg();
  }


  void _onGpsInputChanged() {
    _updateWakeLock();
  }

  void _updateWakeLock() {
    if (_navMode || _gpsInput.isUsbActive) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  void _setPipEnabled(bool enabled) {
    _pipChannel.invokeMethod('setPipEnabled', {'enabled': enabled});
  }
  void _onGpsSmoothTick(Duration elapsed) {
    if (!mounted || _gpsSmoothness <= 0) return;

    _gpsSmoother.smoothness = _gpsSmoothness;
    _gpsSmoother.tick(DateTime.now());

    _syncDisplayFromSmoother();
    _updateImplementGeometry();
    // Do not rebuild full swath here — that caused lag after long jobs.
    if (_navMode) {
      _syncLiveSwathTip();
      _syncNavPathTail();
      _updateLookAhead();
      _runNavLogicIfDue();
    }
    _maybeAutoSelectPaddockFromGps();
    _applyDisplayCamera();
    _notifyDisplayPosition();
  }

  void _applyDisplayCamera() {
    if (!_mapReady || _dispPos == null) return;
    // Discrete swoop in progress — don't fight it with chase.
    if (_cameraSwoopCtrl?.isAnimating == true) return;

    double? targetRot;
    switch (_rotationMode) {
      case RotationMode.northUp:
        final rot = _mapController.camera.rotation;
        if (rot.abs() > 0.05) targetRot = 0;
        break;
      case RotationMode.travelUp:
        final hdg = _tractorHeadingDeg();
        if (hdg != null) targetRot = _nearestRotation(-hdg);
        break;
      case RotationMode.free:
        break;
    }

    final cam = _mapController.camera;

    // Update follow aim when GPS moves enough (throttle).
    LatLng? aimCenter;
    if (_followGps && !_showingHistory) {
      final lastAim = _lastCameraTarget;
      final threshold = _navMode ? 0.12 : _cameraMoveThresholdM;
      if (lastAim == null ||
          const Distance().as(LengthUnit.Meter, lastAim, _dispPos!) >=
              threshold) {
        _lastCameraTarget = _dispPos;
      }
      aimCenter = _lastCameraTarget;
    }

    // First fix / large jump: swoop so startup actually reaches the marker.
    if (aimCenter != null) {
      final jumpM =
          const Distance().as(LengthUnit.Meter, cam.center, aimCenter);
      if (jumpM >= _cameraSwoopDistanceM) {
        _swoopCamera(
          center: aimCenter,
          rotationDeg: targetRot,
        );
        return;
      }
    }

    // Soft chase while the camera still lags the aim (not only when GPS moves).
    LatLng? chaseCenter;
    if (aimCenter != null) {
      final lagM =
          const Distance().as(LengthUnit.Meter, cam.center, aimCenter);
      if (lagM >= _cameraChaseSettleM) chaseCenter = aimCenter;
    }

    if (chaseCenter == null && targetRot == null) return;

    var nextCenter = cam.center;
    var nextRot = cam.rotation;

    if (chaseCenter != null) {
      nextCenter = LatLng(
        cam.center.latitude +
            (chaseCenter.latitude - cam.center.latitude) * _cameraChaseAlpha,
        cam.center.longitude +
            (chaseCenter.longitude - cam.center.longitude) * _cameraChaseAlpha,
      );
    }
    if (targetRot != null) {
      nextRot = cam.rotation + (targetRot - cam.rotation) * _cameraChaseAlpha;
      _lastCameraRotationDeg = targetRot;
    }
    _mapController.moveAndRotate(nextCenter, cam.zoom, nextRot);
  }

  /// Shortest equivalent heading nearest to current camera rotation.
  double _nearestRotation(double degrees) {
    final current = _mapReady ? _mapController.camera.rotation : degrees;
    var best = degrees;
    var bestAbs = (degrees - current).abs();
    for (final candidate in [degrees - 360.0, degrees + 360.0]) {
      final d = (candidate - current).abs();
      if (d < bestAbs) {
        bestAbs = d;
        best = candidate;
      }
    }
    return best;
  }

  void _stopCameraSwoop() {
    _cameraSwoopCtrl?.stop();
    _cameraSwoopCtrl?.dispose();
    _cameraSwoopCtrl = null;
  }

  /// Animated swoop for discrete camera jumps (recenter, mode change, fit).
  void _swoopCamera({
    LatLng? center,
    double? zoom,
    double? rotationDeg,
    Duration duration = _cameraSwoopDuration,
  }) {
    if (!_mapReady) {
      if (center != null) {
        _mapController.move(center, zoom ?? _mapController.camera.zoom);
      }
      if (rotationDeg != null) _mapController.rotate(rotationDeg);
      return;
    }
    _stopCameraSwoop();
    final startCenter = _mapController.camera.center;
    final startZoom = _mapController.camera.zoom;
    final startRot = _mapController.camera.rotation;
    final endCenter = center ?? startCenter;
    final endZoom = zoom ?? startZoom;
    final endRot =
        rotationDeg != null ? _nearestRotation(rotationDeg) : startRot;

    _cameraSwoopCtrl = AnimationController(vsync: this, duration: duration);
    final curved = CurvedAnimation(
      parent: _cameraSwoopCtrl!,
      curve: Curves.easeInOutCubic,
    );
    curved.addListener(() {
      if (!mounted || !_mapReady) return;
      final t = curved.value;
      _mapController.moveAndRotate(
        LatLng(
          startCenter.latitude + (endCenter.latitude - startCenter.latitude) * t,
          startCenter.longitude +
              (endCenter.longitude - startCenter.longitude) * t,
        ),
        startZoom + (endZoom - startZoom) * t,
        startRot + (endRot - startRot) * t,
      );
    });
    _cameraSwoopCtrl!.addStatusListener((status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.dismissed) {
        _lastCameraTarget = endCenter;
        _lastCameraRotationDeg = endRot;
      }
    });
    _cameraSwoopCtrl!.forward();
  }

  // ---------- Helpers ----------
  double _toMeters(double v) => _units == 'feet' ? v / 3.280839895 : v;
  String _lenUnit() => _units == 'feet' ? 'ft' : 'm';

  double _currentWidthDisplay() => _toolDims.width <= 0 ? 3.0 : _toolDims.width;

  double _currentSwathWidthM() => _toMeters(_currentWidthDisplay());

  String _toolQuickReferenceText() {
    final preset = _selectedToolPresetName ?? 'Custom';
    final w = _currentWidthDisplay().toStringAsFixed(1);
    return '$preset · $w ${_lenUnit()}';
  }

  void _openToolSetupDrawer() {
    _drawerTabCtrl.index = 1;
    _scaffoldKey.currentState?.openEndDrawer();
  }

  void _openGpsSettingsDrawer() {
    _drawerTabCtrl.index = 2;
    _scaffoldKey.currentState?.openEndDrawer();
  }

  String _gpsRailLabel() {
    switch (_gpsInput.activeSource) {
      case GpsActiveSource.usb:
        return 'USB';
      case GpsActiveSource.device:
        return 'Device';
      case GpsActiveSource.none:
        return switch (_gpsInput.mode) {
          GpsInputMode.usb => 'USB',
          GpsInputMode.device => 'Device',
          GpsInputMode.auto => 'Auto',
        };
    }
  }

  IconData _gpsRailIcon() {
    switch (_gpsInput.activeSource) {
      case GpsActiveSource.usb:
        return Icons.usb;
      case GpsActiveSource.device:
        return Icons.smartphone;
      case GpsActiveSource.none:
        return Icons.gps_off;
    }
  }

  // Shared floating-circle look for rail chips, Start/A/B, finish, rotate, follow.
  static const double _fabDiameter = 72.0;
  static const double _fabSecondaryDiameter = 56.0;
  static const double _fabElevation = 6;
  /// Margin from screen safe edges to floating controls.
  static const double _fabEdge = 12.0;
  /// Gap between floating controls in a stack/rail.
  static const double _fabGap = 12.0;

  Color get _fabFill {
    final scheme = Theme.of(context).colorScheme;
    return scheme.surface.withOpacity(0.94);
  }
  Color get _fabContent => Theme.of(context).colorScheme.primary;

  Widget _floatingCircleFace({
    required double diameter,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return Material(
      elevation: _fabElevation,
      color: _fabFill,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: Center(child: child),
        ),
      ),
    );
  }

  /// Circular rail button with icon + label inside the circle.
  Widget _jobRailChip({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return _floatingCircleFace(
      diameter: _fabDiameter,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: _fabContent),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                height: 1.1,
                color: _fabContent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _jobSideRail({
    required String paddockLabel,
    required String toolLabel,
    required String areaLabel,
    required String? historyPaddockName,
  }) {
    final load = _openLoadSession;
    final expect = load?.expectedQtyNow;
    final loadLabel = load == null
        ? 'Load'
        : [
            'Load',
            expect == null
                ? 'open'
                : expect >= 1000
                    ? '${(expect / 1000).toStringAsFixed(1)}k ${load.unitLabel}'
                    : '${expect.toStringAsFixed(0)} ${load.unitLabel}',
          ].join('\n');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _jobRailChip(
          icon: Icons.grass,
          label: paddockLabel,
          onTap: () => setState(() {
            _selectedIdx.clear();
            _suppressAutoPaddockSelect = true;
          }),
        ),
        const SizedBox(height: _fabGap),
        _jobRailChip(
          icon: Icons.agriculture,
          label: toolLabel,
          onTap: _openToolSetupDrawer,
        ),
        const SizedBox(height: _fabGap),
        _jobRailChip(
          icon: Icons.square_foot,
          label: areaLabel,
        ),
        const SizedBox(height: _fabGap),
        _jobRailChip(
          icon: _workListPicking ? Icons.done : Icons.playlist_add,
          label: _workListPicking ? 'Done' : 'Add list',
          onTap: _onAddListPressed,
        ),
        const SizedBox(height: _fabGap),
        _jobRailChip(
          icon: Icons.scale,
          label: loadLabel,
          onTap: _openProductLoadSheet,
        ),
        if (historyPaddockName != null) ...[
          const SizedBox(height: _fabGap),
          _jobRailChip(
            icon: Icons.history,
            label: 'History',
            onTap: () => _showPaddockHistory(historyPaddockName),
          ),
        ],
        const SizedBox(height: _fabGap),
        ListenableBuilder(
          listenable: _gpsInput,
          builder: (context, _) => _jobRailChip(
            icon: _gpsRailIcon(),
            label: _gpsRailLabel(),
            onTap: _openGpsSettingsDrawer,
          ),
        ),
      ],
    );
  }

  double _jobSwathWidthM(SavedJob job) => job.resolveSwathWidthM(_currentSwathWidthM());

  double _jobAreaAppliedHa(SavedJob job) => job.areaAppliedHaFor(_currentSwathWidthM());

  double _jobCoveragePercent(SavedJob job) => job.coveragePercentFor(_currentSwathWidthM());

  String _areaText(double ha) => _units == 'feet'
      ? '${(ha * 2.47105).toStringAsFixed(1)} ac'
      : '${ha.toStringAsFixed(1)} ha';

  double _navSelectedTotalHa() {
    final idxs = _jobAreaPaddockIndices();
    return idxs.fold(0.0, (s, i) {
      if (i < 0 || i >= _paddocks.length) return s;
      return s + _paddocks[i].areaHa;
    });
  }

  Iterable<int> _jobAreaPaddockIndices() {
    if (_jobLockedPaddockIdx.isNotEmpty) return _jobLockedPaddockIdx;
    return _selectedIdx;
  }

  /// Applied metres for coverage — same basis as job finish / summary:
  /// paddock-gated length of the simplified boom path (not raw GPS weave).
  double _coverageAppliedDistanceM({bool force = false}) {
    final pathLen = _jobPath.length;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        pathLen == _coverageDistanceCachePathLen &&
        now - _coverageDistanceCacheMs < 200) {
      return _coverageDistanceCacheM;
    }
    final simplified = pathLen < 2
        ? const <LatLng>[]
        : simplifySwathPath(_jobPath, minDistM: _jobSaveSimplifyMinDistM);
    final dist = _paddockGatedPathDistanceM(simplified);
    _coverageDistanceCacheM = dist;
    _coverageDistanceCachePathLen = pathLen;
    _coverageDistanceCacheMs = now;
    return dist;
  }

  double _paddockGatedPathDistanceM(List<LatLng> path) {
    if (path.length < 2) return 0;
    if (_jobAreaPaddockIndices().isEmpty) return pathDistanceMeters(path);
    double total = 0;
    for (var i = 1; i < path.length; i++) {
      final a = path[i - 1];
      final b = path[i];
      if (_inSelectedPaddock(a) && _inSelectedPaddock(b)) {
        total += const Distance().as(LengthUnit.Meter, a, b);
      }
    }
    return total;
  }

  double _navLiveAppliedAreaHa() =>
      _coverageAppliedDistanceM() * _currentSwathWidthM() / 10000.0;

  double _navLiveCoveragePercent() {
    final total = _navSelectedTotalHa();
    if (total <= 0) return 0;
    return (_navLiveAppliedAreaHa() / total * 100).clamp(0, double.infinity);
  }

  double _navLiveAvgSpeedKph() {
    if (_jobStartTime == null) return 0;
    final hrs = DateTime.now().difference(_jobStartTime!).inMilliseconds / 3600000.0;
    if (hrs <= 0) return 0;
    return (_speedDistanceM / 1000.0) / hrs;
  }

  Widget _navDashboard() {
    final topPad = MediaQuery.of(context).padding.top;
    Widget stat(String label, String value) {
      return Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 3),
            Text(
              value,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: Colors.white,
              ),
            ),
          ],
        ),
      );
    }

    return Material(
      elevation: 4,
      color: Colors.black.withOpacity(0.78),
      child: Padding(
        padding: EdgeInsets.fromLTRB(10, topPad + 8, 10, 10),
        child: Row(
          children: [
            stat('Speed', '${_currentSpeedKph.toStringAsFixed(1)} km/h'),
            if (_suggestedTargetSpeedKph != null)
              stat(
                'Target',
                '${_suggestedTargetSpeedKph!.toStringAsFixed(1)} km/h',
              )
            else
              stat('Avg', '${_navLiveAvgSpeedKph().toStringAsFixed(1)} km/h'),
            stat('Covered', _areaText(_navLiveAppliedAreaHa())),
            stat('Coverage', '${_navLiveCoveragePercent().toStringAsFixed(0)}%'),
          ],
        ),
      ),
    );
  }

  /// Round nav action (Start / A / B / map controls).
  /// Expanded hit zone does not affect layout, so edge/gap spacing stays visual.
  Widget _fatRoundActionButton({
    required VoidCallback onPressed,
    String? letter,
    IconData? icon,
    String? heroTag,
    double diameter = _fabDiameter,
    bool expandHit = true,
  }) {
    assert(letter != null || icon != null);
    final hitExtend = expandHit ? diameter / 2 : 0.0;
    final face = _floatingCircleFace(
      diameter: diameter,
      child: letter != null
          ? Text(
              letter,
              style: TextStyle(
                fontSize: diameter * 0.39,
                fontWeight: FontWeight.w800,
                color: _fabContent,
              ),
            )
          : Icon(icon, size: diameter * 0.47, color: _fabContent),
    );
    final wrapped = heroTag == null
        ? face
        : Hero(
            tag: heroTag,
            child: Material(color: Colors.transparent, child: face),
          );
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        gestureSettings: const DeviceGestureSettings(touchSlop: 36),
      ),
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            wrapped,
            Positioned(
              left: -hitExtend,
              top: -hitExtend,
              right: -hitExtend,
              bottom: -hitExtend,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: onPressed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editorTitleChip() {
    String title;
    String? subtitle;
    switch (_tool) {
      case EditorTool.browse:
        if (_editorSelecting) {
          title = '${_selectedIdx.length} selected';
          subtitle = 'Tap to toggle · Select all or Delete below';
        } else {
          title = 'Edit paddocks';
          subtitle = 'Tap to edit · Hold to select · + to create';
        }
      case EditorTool.drawOuter:
        title = _draftPaddockName ?? 'New paddock';
        subtitle = '${_tempOuter.length} points — Add at crosshair';
      case EditorTool.drawHole:
        title = 'New hole';
        subtitle = '${_tempHole.length} points — Add at crosshair';
      case EditorTool.edit:
        final name = (_editingIdx != null && _editingIdx! < _paddocks.length)
            ? _paddocks[_editingIdx!].name
            : 'Paddock';
        title = 'Editing: $name';
        if (_vertexLiveMove && _selectedVertexIdx != null) {
          final where = _selectedHoleIdx == null ? 'outer' : 'hole';
          subtitle = 'Dragging $where vertex — pan to move';
        } else {
          subtitle = 'Tap a vertex to drag, or Add / Hole';
        }
    }
    return Material(
      elevation: 2,
      color: Theme.of(context).colorScheme.surface.withOpacity(0.94),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _editorSelectBar() {
    final allSelected =
        _paddocks.isNotEmpty && _selectedIdx.length == _paddocks.length;
    return Material(
      elevation: 6,
      color: Theme.of(context).colorScheme.surface.withOpacity(0.96),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            TextButton(
              onPressed: _editorDone,
              child: const Text('Done'),
            ),
            TextButton(
              onPressed: _paddocks.isEmpty
                  ? null
                  : () {
                      if (allSelected) {
                        setState(() {
                          _selectedIdx.clear();
                          _editorSelecting = false;
    });
    _updateWakeLock();
    _setPipEnabled(false);
    _rebuildPaddockLayers();
                      } else {
                        _editorSelectAll();
                      }
                    },
              child: Text(allSelected ? 'None' : 'Select all'),
            ),
            const Spacer(),
            ElevatedButton.icon(
              onPressed:
                  _selectedIdx.isEmpty ? null : _deleteSelectedPaddocks,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(
                _selectedIdx.isEmpty
                    ? 'Delete'
                    : 'Delete (${_selectedIdx.length})',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editorActionBar() {
    final canDelete =
        _tool == EditorTool.edit && _selectedVertexIdx != null;
    final canDeleteHole =
        _tool == EditorTool.edit && _selectedHoleIdx != null;
    final canFinishOuter =
        _tool == EditorTool.drawOuter && _tempOuter.length >= 3;
    final canFinishHole =
        _tool == EditorTool.drawHole && _tempHole.length >= 3;
    final canUndo = (_tool == EditorTool.drawOuter && _tempOuter.isNotEmpty) ||
        (_tool == EditorTool.drawHole && _tempHole.isNotEmpty);

    Widget chip(String label, VoidCallback? onTap, {bool primary = false}) {
      final enabled = onTap != null;
      final scheme = Theme.of(context).colorScheme;
      return Material(
        color: !enabled
            ? scheme.surfaceContainerHighest.withOpacity(0.5)
            : primary
                ? scheme.primary
                : scheme.surface,
        elevation: enabled ? 2 : 0,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: !enabled
                    ? scheme.onSurface.withOpacity(0.38)
                    : primary
                        ? scheme.onPrimary
                        : scheme.primary,
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: Theme.of(context).colorScheme.surface.withOpacity(0.94),
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              chip('Add', _addVertexAtCrosshair),
              if (_tool == EditorTool.edit) ...[
                const SizedBox(width: 8),
                chip('Hole', _startDrawHole),
                const SizedBox(width: 8),
                chip('Delete', canDelete ? _deleteSelectedVertex : null),
                if (canDeleteHole) ...[
                  const SizedBox(width: 8),
                  chip('Del hole', _deleteSelectedHole),
                ],
              ],
              if (_tool == EditorTool.drawOuter ||
                  _tool == EditorTool.drawHole) ...[
                const SizedBox(width: 8),
                chip('Undo', canUndo ? _undoLastPoint : null),
                const SizedBox(width: 8),
                chip(
                  'Finish',
                  canFinishOuter || canFinishHole ? _finishDrawing : null,
                  primary: true,
                ),
              ],
              const SizedBox(width: 8),
              chip('Done', _editorDone),
            ],
          ),
        ),
      ),
    );
  }

  String _gpsSmoothnessLabel() {
    if (_gpsSmoothness <= 0) {
      return 'Off — marker and map snap to each GPS fix.';
    }
    final animSec = _gpsSmoothness * _gpsSmoother.intervalMs / 1000.0;
    final fixSec = _gpsSmoother.intervalMs / 1000.0;
    return 'Animates over ${animSec.toStringAsFixed(1)} s per fix '
        '(~${(_gpsSmoothness * 100).toStringAsFixed(0)}% of ${fixSec.toStringAsFixed(1)} s interval). '
        'Higher = smoother but more lag.';
  }

  double _gpsToPivotM() => _toMeters(ToolSetupDimensions.kGpsPivotOffset);
  double _gpsLateralM() => _toMeters(_toolDims.gpsLateralOffset);
  double _hitchToAxleM() => _toMeters(_toolDims.hitchToAxle);

  void _rebuildJobPathFromGps() {
    final forward = filterForwardGpsPath(_gpsRecordPath);
    _jobPath = implementCenterPathFromGps(
      forward,
      gpsBehindM: _gpsToPivotM(),
      gpsLateralM: _gpsLateralM(),
      hitchToAxleM: _hitchToAxleM(),
      boomLateralM: _toMeters(_offset),
    );
  }

  double? _pathTravelBearingDeg() {
    if (_gpsRecordPath.length >= 2) {
      final a = _gpsRecordPath[_gpsRecordPath.length - 2];
      final b = _gpsRecordPath.last;
      return const Distance().bearing(a, b);
    }
    return _lastTravelBearingDeg;
  }

  LatLng? _liveGpsForSwathTip() {
    final live = _currentPos ?? _dispPos;
    if (live == null) return null;
    if (_gpsRecordPath.isEmpty) return live;
    final anchor = _gpsRecordPath.last;
    if (_gpsRecordPath.length < 2) return live;
    final prev = _gpsRecordPath[_gpsRecordPath.length - 2];
    if (isBackwardGpsStep(anchor, prev, live)) return null;
    return live;
  }

  ImplementGeometry _implementGeometryAt(
    LatLng gps, {
    required double bearingDeg,
  }) {
    return ImplementTracker.compute(
      gpsPos: gps,
      headingDeg: bearingDeg,
      gpsToPivotM: _gpsToPivotM(),
      gpsLateralOffsetM: _gpsLateralM(),
      hitchToAxleM: _hitchToAxleM(),
      widthM: _currentSwathWidthM(),
      lateralOffsetM: _toMeters(_offset),
    );
  }

  void _accumulateSpeedDistance(GpsFix p) {
    if (!_navMode || _lastSpeedFixTime == null || !p.hasSpeed) return;
    final bucket = p.timestamp.millisecondsSinceEpoch ~/ _navSampleBucketMs;
    if (_lastSpeedSampleBucket == bucket) return;
    final dt =
        p.timestamp.difference(_lastSpeedFixTime!).inMilliseconds / 1000.0;
    if (dt > 0 && dt < 20) {
      _speedDistanceM += p.speedMps! * dt;
      _lastSpeedSampleBucket = bucket;
    }
  }

  List<Polyline> _buildImplementPolylines(ImplementGeometry g) {
    return [
      Polyline(
        points: [g.gpsPos, g.hitchPivot],
        color: Colors.blue.shade700.withOpacity(0.85),
        strokeWidth: 2.0,
        isDotted: true,
      ),
      Polyline(
        points: [g.hitchPivot, g.trailerAxle],
        color: Colors.orange.shade800.withOpacity(0.95),
        strokeWidth: 3.0,
      ),
      Polyline(
        points: [g.trailerAxle, g.implementCenter],
        color: Colors.deepOrange.shade400.withOpacity(0.95),
        strokeWidth: 2.5,
        isDotted: true,
      ),
      Polyline(
        points: [g.boomLeft, g.boomRight],
        color: _swathColor.withOpacity(0.95),
        strokeWidth: math.max(3.0, _headingWidth),
      ),
    ];
  }

  /// Heading for boom overlay — matches the blue look-ahead line.
  double _boomDisplayHeadingDeg() =>
      _tractorHeadingDeg() ?? _pathTravelBearingDeg() ?? 0.0;

  ImplementGeometry? _updateImplementGeometry({
    LatLng? gpsPos,
    double? gpsHeading,
  }) {
    final pos = gpsPos ?? _dispPos ?? _currentPos;
    if (pos == null) {
      _implementPolysNotifier.value = [];
      return null;
    }

    final double heading = _navMode
        ? _boomDisplayHeadingDeg()
        : (gpsHeading ?? _dispHeadingDeg ?? _currentHeadingDeg ?? 0.0);

    final geom = _implementGeometryAt(pos, bearingDeg: heading);
    _implementTracker.implementHeadingDeg = heading;
    _implementTracker.hitchPivot = geom.hitchPivot;
    _implementTracker.trailerAxle = geom.trailerAxle;
    _implementTracker.implementCenter = geom.implementCenter;
    _implementPolysNotifier.value = _buildImplementPolylines(geom);
    return geom;
  }

  void _applyMapRotation(double degrees, {bool animate = true}) {
    if (!_mapReady) {
      _mapController.rotate(degrees);
      return;
    }
    final best = _nearestRotation(degrees);
    if (animate) {
      _swoopCamera(rotationDeg: best);
    } else {
      _mapController.rotate(best);
      _lastCameraRotationDeg = best;
    }
  }

  void _resetToMapDefaults({bool moveToGps = true}) {
    setState(() {
      _rotationMode = RotationMode.northUp;
      _followGps = true;
    });
    if (_mapReady) {
      _swoopCamera(
        center: moveToGps ? _dispPos : null,
        rotationDeg: 0,
      );
    }
  }

  void _onMapPositionChanged(MapPosition position, bool hasGesture) {
    _maybeRefreshPaddockLayersForZoom();
    if (_editorMode &&
        _vertexLiveMove &&
        !_suppressVertexLiveMove &&
        hasGesture) {
      _snapSelectedVertexToCenter(persist: false);
    }
    if (!hasGesture || _showingHistory) return;
    _stopCameraSwoop();
    // Stop follow immediately so controller moves don't fight the pan gesture.
    if (_followGps) {
      setState(() => _followGps = false);
    }
  }

  void _onMapEvent(MapEvent event) {
    if (_editorMode && _vertexLiveMove && !_suppressVertexLiveMove) {
      // Fling doesn't always set hasGesture on positionChanged.
      if (event is MapEventFlingAnimation) {
        _snapSelectedVertexToCenter(persist: false);
      }
      if (event is MapEventMoveEnd ||
          event is MapEventFlingAnimationEnd ||
          event is MapEventDoubleTapZoomEnd) {
        _snapSelectedVertexToCenter(persist: true);
      }
    }
    if (event is MapEventRotateEnd && mounted) {
      setState(() {});
    }
    if (event is MapEventRotateStart ||
        (event is MapEventRotate &&
            event.source != MapEventSource.mapController &&
            event.source != MapEventSource.fitCamera)) {
      if (_rotationMode != RotationMode.free && mounted) {
        setState(() => _rotationMode = RotationMode.free);
      }
    }
  }

  bool get _showFollowGpsButton =>
      _dispPos != null && !_followGps && !_showingHistory && _mapReady;

  void _resetCameraThrottle() {
    _lastCameraTarget = null;
    _lastCameraRotationDeg = null;
  }

  /// flutter_map: avoid move/rotate in the same frame as onMapReady.
  void _runAfterMapFrame(VoidCallback fn) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _mapReady) fn();
    });
  }

  void _recenter() {
    if (_dispPos != null && _mapReady) {
      setState(() => _followGps = true);
      _resetCameraThrottle();
      final hdg = _rotationMode == RotationMode.travelUp
          ? _tractorHeadingDeg()
          : null;
      _swoopCamera(
        center: _dispPos,
        rotationDeg: hdg != null ? -hdg : (_rotationMode == RotationMode.northUp ? 0 : null),
      );
    }
  }

  void _cycleRotationMode() {
    setState(() {
      switch (_rotationMode) {
        case RotationMode.northUp: _rotationMode = RotationMode.travelUp; break;
        case RotationMode.travelUp: _rotationMode = RotationMode.free; break;
        case RotationMode.free: _rotationMode = RotationMode.northUp; break;
      }
    });
    _resetCameraThrottle();
    if (_mapReady) {
      if (_rotationMode == RotationMode.northUp) _applyMapRotation(0);
      if (_rotationMode == RotationMode.travelUp) {
        final hdg = _tractorHeadingDeg();
        if (hdg != null) _applyMapRotation(-hdg);
      }
    }
  }

  IconData _rotationIcon() {
    switch (_rotationMode) {
      case RotationMode.northUp: return Icons.explore;
      case RotationMode.travelUp: return Icons.navigation;
      case RotationMode.free: return Icons.threed_rotation;
    }
  }

  LatLng _offsetMeters(LatLng p, double eastM, double northM) {
    const Rm = 111320.0;
    final dLat = northM / Rm;
    final dLng = eastM / (Rm * math.cos(p.latitude * math.pi / 180.0));
    return LatLng(p.latitude + dLat, p.longitude + dLng);
  }

  bool _inSelectedPaddock(LatLng p) {
    final idxs = _jobAreaPaddockIndices();
    if (idxs.isEmpty) return true;
    for (final i in idxs) {
      if (i < 0 || i >= _paddocks.length) continue;
      final pd = _paddocks[i];
      if (pointInPolygon(p, pd.outer, pd.holes)) return true;
    }
    return false;
  }

  // ---------- Label helpers ----------
  void _rebuildPaddockLayers() {
    if (!mounted) return;
    final polys = <Polygon>[];
    final labels = <Marker>[];
    var zoom = 0.0;
    if (_mapReady) {
      try {
        zoom = _mapController.camera.zoom;
      } catch (_) {
        zoom = 0.0;
      }
    }
    final showLabels = zoom >= 15.0;
    _paddockLabelsZoomVisible = showLabels;

    for (int i = 0; i < _paddocks.length; i++) {
      final pd = _paddocks[i];
      final isSel = _selectedIdx.contains(i);
      final inList = _workList.contains(pd.name);
      final listDone = inList && _workList.completedNames.contains(pd.name);
      Color border;
      var borderW = 2.0;
      var extraFill = 0.0;
      if (isSel) {
        border = Colors.yellow.shade700;
        borderW = 3.5;
        extraFill = 0.08;
      } else if (listDone) {
        border = Colors.teal.shade700;
        borderW = 3.0;
        extraFill = 0.10;
      } else if (inList) {
        border = Colors.orange.shade800;
        borderW = 3.0;
        extraFill = 0.10;
      } else {
        border = _overlayColor;
      }
      polys.add(
        Polygon(
          points: pd.outer,
          holePointsList: pd.holes,
          color: _overlayColor.withOpacity(
            (_overlayOpacity + extraFill).clamp(0.0, 1.0),
          ),
          borderColor: border,
          borderStrokeWidth: borderW,
          isFilled: true,
        ),
      );
      if (showLabels) {
        final labelAnchor = pd.labelPoint;
        labels.add(
          Marker(
            point: labelAnchor,
            width: 200,
            height: 52,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pd.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Colors.black87,
                  ),
                ),
                Text(
                  _areaText(pd.areaHa),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontStyle: FontStyle.italic,
                    fontSize: 11,
                    color: Colors.black54,
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    _paddockPolysNotifier.value = polys;
    _paddockLabelsNotifier.value = labels;
  }

  void _maybeRefreshPaddockLayersForZoom() {
    if (!_mapReady) return;
    final showLabels = _mapController.camera.zoom >= 15.0;
    if (showLabels != _paddockLabelsZoomVisible) {
      _rebuildPaddockLayers();
    }
  }

  void _closeEndDrawer() {
    _scaffoldKey.currentState?.closeEndDrawer();
  }

  /// Handle Android/iOS system back. Returns true if the event was consumed.
  Future<bool> _handleSystemBack() async {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold?.isEndDrawerOpen == true) {
      scaffold!.closeEndDrawer();
      if (_histSelecting) {
        setState(() {
          _histSelecting = false;
          _histSelected.clear();
        });
      }
      return true;
    }

    if (_showingHistory) {
      _exitHistory();
      return true;
    }

    if (_completedJobSummary != null) {
      setState(_dismissCompletedJobSummary);
      return true;
    }

    if (_workListPicking) {
      _endWorkListPicking();
      return true;
    }

    if (_navMode) {
      await _onBackDuringNavigation();
      return true;
    }

    if (_editorMode) {
      if ((_tool == EditorTool.drawOuter && _tempOuter.isNotEmpty) ||
          (_tool == EditorTool.drawHole && _tempHole.isNotEmpty)) {
        _undoLastPoint();
        return true;
      }
      if (_tool == EditorTool.edit && _vertexLiveMove) {
        setState(() => _clearVertexSelection(persist: true));
        return true;
      }
      if (_tool == EditorTool.edit ||
          _tool == EditorTool.drawOuter ||
          _tool == EditorTool.drawHole) {
        _editorDone();
        return true;
      }
      _exitEditorMode();
      return true;
    }

    if (_selectedIdx.isNotEmpty) {
      setState(() {
        _selectedIdx.clear();
        _suppressAutoPaddockSelect = true;
      });
      _rebuildPaddockLayers();
      return true;
    }

    return false;
  }

  Future<void> _onBackDuringNavigation() async {
    // Nothing meaningful recorded yet — just leave nav mode.
    if (_jobStartTime == null || _jobPath.length < 2) {
      await _finishJob();
      return;
    }
    if (!mounted) return;
    final choice = await showFadeDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End job?'),
        content: const Text('Finish and save this job, or keep navigating?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('Keep going'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'finish'),
            child: const Text('Finish'),
          ),
        ],
      ),
    );
    if (choice == 'finish' && mounted) await _finishJob();
  }

  Future<void> _showHistoryJobsFromPaths(List<String> paths) async {
    if (paths.isEmpty || !mounted) return;
    _closeEndDrawer();
    showFadeDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Material(
        type: MaterialType.transparency,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
    try {
      final jobs = <SavedJob>[];
      for (final p in paths) {
        jobs.add(await JobStore.read(p));
      }
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _showHistoryJobs(jobs);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load job: $e')),
      );
    }
  }

  // ---------- Swath builder ----------
  List<Polygon> _swathPolygonsForJob(SavedJob job) {
    return _swathPolygonsFromPath(job.path, _jobSwathWidthM(job));
  }

  List<Polygon> _swathPolygonsFromPath(
    List<LatLng> path,
    double widthM, {
    Color? color,
    double? opacity,
  }) {
    final c = color ?? _swathColor;
    final o = opacity ?? _swathOpacity;
    return buildSwathRingsFromPath(path, widthM).map((ring) => Polygon(
      points: ring,
      color: c.withOpacity(o),
      borderColor: Colors.transparent,
      borderStrokeWidth: 0,
      isFilled: true,
    )).toList();
  }

  void _clearSwathDisplay() {
    _committedSwathPolys.clear();
    _swathCommittedBoomLen = 0;
    _lastSwathCommitMs = 0;
    _swathCommittedNotifier.value = [];
    _swathLiveNotifier.value = null;
    _navPathCommittedNotifier.value = null;
    _navPathTailNotifier.value = null;
  }

  Polygon? _swathPolygonFromRing(List<LatLng> ring) {
    if (ring.length < 3) return null;
    return Polygon(
      points: ring,
      color: _swathColor.withOpacity(_swathOpacity),
      borderColor: Colors.transparent,
      borderStrokeWidth: 0,
      isFilled: true,
    );
  }

  List<LatLng> _liveBoomTipPath() {
    final boom = _jobPath;
    if (boom.isEmpty) return const [];
    // Short tip only — committed display already covers boom[0..committed).
    final start = boom.length > 3 ? boom.length - 3 : 0;
    final tip = List<LatLng>.from(boom.sublist(start));
    final live = _liveGpsForSwathTip();
    final bearing = _pathTravelBearingDeg();
    if (live != null && bearing != null) {
      final center = _implementGeometryAt(live, bearingDeg: bearing).implementCenter;
      if (tip.isEmpty ||
          const Distance().as(LengthUnit.Meter, tip.last, center) >= 0.05) {
        tip.add(center);
      }
    }
    return tip;
  }

  void _syncLiveSwathTip() {
    if (!_navMode) {
      _swathLiveNotifier.value = null;
      return;
    }
    final tipPath = _liveBoomTipPath();
    if (tipPath.length < 2) {
      _swathLiveNotifier.value = null;
      return;
    }
    final ring = buildSwathRingFromPath(tipPath, _currentSwathWidthM());
    _swathLiveNotifier.value = _swathPolygonFromRing(ring);
  }

  /// Rebuild continuous swath polygons from the boom path (throttled).
  /// Chunked append left hairline gaps at every join; one ring set stays filled.
  void _maybeCommitSwath({bool force = false}) {
    if (!_navMode) return;
    final boom = _jobPath;
    if (boom.length < 2) return;

    final ms = DateTime.now().millisecondsSinceEpoch;
    if (!force && ms - _lastSwathCommitMs < _swathCommitIntervalMs) return;

    if (!force && _swathCommittedBoomLen > 0) {
      var advanceM = 0.0;
      final from = _swathCommittedBoomLen.clamp(1, boom.length);
      for (int i = from; i < boom.length; i++) {
        advanceM += const Distance().as(LengthUnit.Meter, boom[i - 1], boom[i]);
      }
      final newPts = boom.length - _swathCommittedBoomLen;
      if (advanceM < _swathCommitMinAdvanceM && newPts < 4) return;
    }

    _lastSwathCommitMs = ms;
    _swathCommittedBoomLen = boom.length;

    final displayPath = boom.length > 24
        ? simplifySwathPath(boom, minDistM: _swathDisplaySimplifyMinDistM)
        : List<LatLng>.from(boom);
    if (displayPath.length < 2) return;

    final rings = buildSwathRingsFromPath(displayPath, _currentSwathWidthM());
    _committedSwathPolys.clear();
    for (final ring in rings) {
      final poly = _swathPolygonFromRing(ring);
      if (poly != null) _committedSwathPolys.add(poly);
    }
    _swathCommittedNotifier.value = List<Polygon>.from(_committedSwathPolys);
  }

  void _syncSwathDisplay({bool forceCommit = false}) {
    if (!_navMode) {
      // Don't wipe a finished-job preview sitting under the summary panel.
      if (_completedJobSummary == null) {
        _clearSwathDisplay();
      }
      return;
    }
    _maybeCommitSwath(force: forceCommit);
    _syncLiveSwathTip();
  }

  void _syncNavPathCommitted() {
    if (_jobPath.length < 2) {
      if (_navPathCommittedNotifier.value != null) {
        _navPathCommittedNotifier.value = null;
      }
      return;
    }
    _navPathCommittedNotifier.value = Polyline(
      points: List<LatLng>.from(_jobPath),
      strokeWidth: 2.5,
      color: _swathColor.withOpacity(_swathOpacity),
    );
  }

  void _syncNavPathTail() {
    if (!_navMode || _jobPath.isEmpty) {
      if (_navPathTailNotifier.value != null) _navPathTailNotifier.value = null;
      return;
    }
    final bearing = _pathTravelBearingDeg();
    final live = _liveGpsForSwathTip();
    if (bearing == null || live == null) {
      if (_navPathTailNotifier.value != null) _navPathTailNotifier.value = null;
      return;
    }
    final tip = _implementGeometryAt(live, bearingDeg: bearing).implementCenter;
    final last = _jobPath.last;
    if (const Distance().as(LengthUnit.Meter, last, tip) < 0.01) {
      if (_navPathTailNotifier.value != null) _navPathTailNotifier.value = null;
      return;
    }
    _navPathTailNotifier.value = Polyline(
      points: [last, tip],
      strokeWidth: 2.5,
      color: _swathColor.withOpacity(_swathOpacity),
    );
  }

  void _updateNavPathDisplay() {
    _syncNavPathCommitted();
    _syncNavPathTail();
  }

  void _refreshSwathPolygons() {
    _rebuildJobPathFromGps();
    _syncSwathDisplay(forceCommit: true);
  }

  void _rebuildNavOverlays() {
    if (_jobPath.length >= 2) {
      _syncNavPathCommitted();
      _syncNavPathTail();
    } else {
      _navPathCommittedNotifier.value = null;
      _navPathTailNotifier.value = null;
    }
    _refreshSwathPolygons();
  }

  void _maybeRecordSwathFromGps(GpsFix p) {
    if (!_navMode) return;
    final gps = _currentPos;
    if (gps == null) return;

    // One path sample per NMEA epoch (RMC+GGA used to double applied metres).
    final bucket = p.timestamp.millisecondsSinceEpoch ~/ _navSampleBucketMs;
    if (_lastSwathRecordBucket == bucket) return;

    final prev = _gpsRecordPath.isNotEmpty ? _gpsRecordPath.last : null;
    var segM = 0.0;
    if (prev != null) {
      segM = const Distance().as(LengthUnit.Meter, prev, gps);
      if (segM < _minGpsRecordM) return;
      if (_gpsRecordPath.length >= 2 &&
          isBackwardGpsStep(prev, _gpsRecordPath[_gpsRecordPath.length - 2], gps)) {
        return;
      }
      if (segM > _maxGpsJumpM) {
        _gpsRecordPath.add(gps);
        _lastSwathRecordBucket = bucket;
        _lastTravelBearingDeg = const Distance().bearing(prev, gps);
        _rebuildJobPathFromGps();
        _syncNavPathCommitted();
        _syncSwathDisplay(forceCommit: true);
        return;
      }
    }

    _gpsRecordPath.add(gps);
    _lastSwathRecordBucket = bucket;
    if (prev != null) {
      _lastTravelBearingDeg = const Distance().bearing(prev, gps);
    }
    _rebuildJobPathFromGps();

    _syncNavPathCommitted();
    _syncNavPathTail();
    _maybeCommitSwath();
    _syncLiveSwathTip();
    _navHudTickNotifier.value++;
  }

  // ---------- Look-ahead line ----------
  void _updateLookAhead() {
    if (!_navMode || _dispPos == null) {
      if (_lookAheadNotifier.value != null) {
        _lookAheadNotifier.value = null;
      }
      return;
    }
    final heading = (_tractorHeadingDeg() ?? 0.0) * math.pi / 180.0;
    final lookM = _headingLengthM.clamp(1.0, 200.0);

    final northM = lookM * math.cos(heading);
    final eastM = lookM * math.sin(heading);
    final end = _offsetMeters(_dispPos!, eastM, northM);

    _lookAheadNotifier.value = Polyline(
      points: [_dispPos!, end],
      strokeWidth: _headingWidth.clamp(2.0, 12.0),
      color: _headingColor.withOpacity(0.95),
      isDotted: _headingDashed,
    );
  }

  // ---------- Guidance generation & closest active line ----------
  void _syncNavLinePolylines() {
    final polys = <Polyline>[];
    for (int i = 0; i < _guidanceParallelLines.length; i++) {
      final active = i == _activeLineIndex;
      for (final seg in _guidanceParallelLines[i]) {
        if (seg.length < 2) continue;
        polys.add(Polyline(
          points: seg,
          color: _guidanceColor,
          strokeWidth: active ? 4.0 : 2.2,
          isDotted: !active,
        ));
      }
    }
    _navLinesNotifier.value = polys;
  }

  /// A→B bearing when traveling forward, B→A bearing when traveling reverse.
  double _guidanceTravelBearingDeg() {
    if (_pointA == null || _pointB == null) {
      return _tractorHeadingDeg() ?? 0;
    }
    final ab = const Distance().bearing(_pointA!, _pointB!);
    final h = _tractorHeadingDeg();
    if (h == null) return ab;
    var diff = (h - ab) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    if (diff.abs() > 90) return (ab + 180) % 360;
    return ab;
  }

  ({double distance, double signed}) _crossTrackToPolyline(
    LatLng p,
    List<LatLng> line,
    double travelBearingDeg,
  ) {
    if (line.length < 2) {
      return (distance: double.infinity, signed: 0);
    }

    double bestDist = double.infinity;
    double bestSigned = 0;
    final gRad = travelBearingDeg * math.pi / 180.0;
    final rE = math.cos(gRad);
    final rN = -math.sin(gRad);

    for (int i = 0; i < line.length - 1; i++) {
      final a = line[i];
      final b = line[i + 1];

      const rm = 111320.0;
      final lat0 = ((a.latitude + b.latitude + p.latitude) / 3) * math.pi / 180.0;
      final cosLat = math.cos(lat0);
      final ax = a.longitude * rm * cosLat;
      final ay = a.latitude * rm;
      final bx = b.longitude * rm * cosLat;
      final by = b.latitude * rm;
      final px = p.longitude * rm * cosLat;
      final py = p.latitude * rm;

      final vx = bx - ax;
      final vy = by - ay;
      final wx = px - ax;
      final wy = py - ay;

      final c1 = vx * wx + vy * wy;
      final c2 = vx * vx + vy * vy;

      double hx;
      double hy;
      if (c1 <= 0) {
        hx = ax;
        hy = ay;
      } else if (c2 <= c1) {
        hx = bx;
        hy = by;
      } else {
        final t = c1 / c2;
        hx = ax + t * vx;
        hy = ay + t * vy;
      }

      final latE = px - hx;
      final latN = py - hy;
      final d = math.sqrt(latE * latE + latN * latN);
      final signed = -(latE * rE + latN * rN);

      if (d < bestDist) {
        bestDist = d;
        bestSigned = signed;
      }
    }

    return (distance: bestDist, signed: bestSigned);
  }

  void _buildGuidance(LatLng a, LatLng b) {
    final widthM = (_toMeters(_width) <= 0) ? 3.0 : _toMeters(_width);
    final offM = _toMeters(_offset);

    const Rm = 111320.0;
    final lat0 = ((a.latitude + b.latitude) * 0.5) * math.pi / 180.0;
    final dE = (b.longitude - a.longitude) * Rm * math.cos(lat0);
    final dN = (b.latitude - a.latitude) * Rm;
    final len = math.sqrt(dE * dE + dN * dN);
    if (len == 0) return;

    final tE = dE / len;
    final tN = dN / len;
    final nE = -tN;
    final nN =  tE;

    LatLng offsetM(LatLng p, double e, double n) => _offsetMeters(p, e, n);

    final aOff = offsetM(a, -nE * offM, -nN * offM);
    final bOff = offsetM(b, -nE * offM, -nN * offM);

    List<List<LatLng>> clipJob(LatLng aa, LatLng bb) {
      final out = <List<LatLng>>[];
      final jobIdx = _jobAreaPaddockIndices();
      if (jobIdx.isEmpty) {
        final vb = _mapController.camera.visibleBounds;
        const samples = 360;
        var seg = <LatLng>[];
        for (int i = 0; i <= samples; i++) {
          final t = i / samples;
          final p = LatLng(aa.latitude + (bb.latitude - aa.latitude) * t, aa.longitude + (bb.longitude - aa.longitude) * t);
          if (_inBounds(p, vb, padDeg: 0.00008)) {
            seg.add(p);
          } else {
            if (seg.length >= 2) out.add(seg);
            seg = <LatLng>[];
          }
        }
        if (seg.length >= 2) out.add(seg);
        return out;
      }
      for (final i in jobIdx) {
        if (i < 0 || i >= _paddocks.length) continue;
        final pd = _paddocks[i];
        out.addAll(clipLineABToPolygonExact(aa, bb, pd.outer, pd.holes));
      }
      return out;
    }

    final polylines = <List<List<LatLng>>>[];
    final mid = LatLng((a.latitude + b.latitude) * 0.5, (a.longitude + b.longitude) * 0.5);

    double maxSpan;
    double alongExtentM;
    final jobIdx = _jobAreaPaddockIndices();
    if (jobIdx.isEmpty) {
      maxSpan = _approxSpanMeters(_mapController.camera.visibleBounds);
      alongExtentM = maxSpan * 2;
    } else {
      final rings = <List<LatLng>>[];
      for (final i in jobIdx) {
        if (i < 0 || i >= _paddocks.length) continue;
        rings.add(_paddocks[i].outer);
      }
      final perpExtent = guidancePerpendicularExtentM(
        origin: mid,
        normalEast: nE,
        normalNorth: nN,
        outerRings: rings,
      );
      maxSpan = guidanceParallelSpanM(
        perpendicularExtentM: perpExtent,
        safetyFactor: _guidanceSafetyFactor,
        capM: _guidanceMaxSpanCapM,
        minSpanM: widthM,
      );
      alongExtentM = guidanceAlongTrackExtentM(
        origin: mid,
        tangentEast: tE,
        tangentNorth: tN,
        outerRings: rings,
      );
    }
    final alongL = alongExtentM * _guidanceAlongTrackMargin;

    void addParallel(double kMeters) {
      final baseA = offsetM(aOff, nE * kMeters, nN * kMeters);
      final baseB = offsetM(bOff, nE * kMeters, nN * kMeters);

      final extA = offsetM(baseA, -tE * alongL, -tN * alongL);
      final extB = offsetM(baseB, tE * alongL, tN * alongL);

      final segs = clipJob(extA, extB);
      if (segs.isNotEmpty) polylines.add(segs);
    }

    // centre A–B line first, then parallels at implement width.
    addParallel(0);

    for (double k = widthM; k <= maxSpan; k += widthM) {
      addParallel(k);
      addParallel(-k);
    }

    _guidanceParallelLines = polylines;
    _activeLineIndex = 0;
    _syncNavLinePolylines();
    _updateActiveGuidanceLine();
    if (mounted) setState(() {});
  }

  void _updateActiveGuidanceLine() {
    if (_dispPos == null ||
        _guidanceParallelLines.isEmpty ||
        _pointA == null ||
        _pointB == null) {
      if (_signedErrorNotifier.value != 0) _signedErrorNotifier.value = 0;
      return;
    }

    final p = _dispPos!;
    final travelBearing = _guidanceTravelBearingDeg();
    final lineCount = _guidanceParallelLines.length;

    var bestIdx = _activeLineIndex.clamp(0, lineCount - 1);
    var bestDist = double.infinity;

    void evalIndex(int i) {
      for (final seg in _guidanceParallelLines[i]) {
        final r = _crossTrackToPolyline(p, seg, travelBearing);
        if (r.distance < bestDist) {
          bestDist = r.distance;
          bestIdx = i;
        }
      }
    }

    final center = _activeLineIndex.clamp(0, lineCount - 1);
    final lo = math.max(0, center - _guidanceScanRadius);
    final hi = math.min(lineCount - 1, center + _guidanceScanRadius);
    for (int i = lo; i <= hi; i++) evalIndex(i);
    if (bestIdx == lo || bestIdx == hi) {
      for (int i = 0; i < lineCount; i++) {
        if (i >= lo && i <= hi) continue;
        evalIndex(i);
      }
    }

    var signed = 0.0;
    var signedDist = double.infinity;
    for (final seg in _guidanceParallelLines[bestIdx]) {
      final r = _crossTrackToPolyline(p, seg, travelBearing);
      if (r.distance < signedDist) {
        signedDist = r.distance;
        signed = r.signed;
      }
    }
    if (_signedErrorNotifier.value != signed) {
      _signedErrorNotifier.value = signed;
    }

    if (bestIdx != _activeLineIndex) {
      _activeLineIndex = bestIdx;
      _syncNavLinePolylines();
    }
  }

  /// GPS / tractor heading — used for map rotation, look-ahead, and steer HUD.
  double? _tractorHeadingDeg() => _dispHeadingDeg ?? _currentHeadingDeg;

  bool _inBounds(LatLng p, LatLngBounds b, {double padDeg = 0}) {
    return p.latitude >= (b.south - padDeg) &&
        p.latitude <= (b.north + padDeg) &&
        p.longitude >= (b.west - padDeg) &&
        p.longitude <= (b.east + padDeg);
  }

  double _approxSpanMeters(LatLngBounds b) {
    final latSpanM = (b.north - b.south).abs() * 111320.0;
    final midLat = (b.north + b.south) / 2.0;
    final lngSpanM = (b.east - b.west).abs() * 111320.0 * math.cos(midLat * math.pi / 180.0);
    return math.max(latSpanM, lngSpanM) * 0.75;
  }

  // ---------- JSON load ----------
  Future<void> _loadFarmJson() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.first;
    final bytes = f.bytes ?? (f.path != null ? await io.File(f.path!).readAsBytes() : null);
    if (bytes == null) return;

    final parsed = GeoJsonParser.parseBytes(bytes);
    if (parsed.error != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('JSON error: ${parsed.error}')));
      return;
    }

    await _persistFarmJson(bytes);
    setState(() {
      _paddocks = parsed.paddocks;
      _selectedIdx.clear();
      _jobLockedPaddockIdx.clear();
      _suppressAutoPaddockSelect = false;
      _navMode = false;
      _navLinesNotifier.value = [];
      _guidanceParallelLines = [];
      _pointA = null;
      _pointB = null;
      _lookAheadNotifier.value = null;
      _clearSwathDisplay();
      _maybeAutoSelectPaddockFromGps();
    });
    _pruneWorkListToFarm();
    _rebuildPaddockLayers();

    if (_paddocks.isNotEmpty && _mapReady) {
      _mapController.move(_paddocks.first.labelPoint, 16);
    }
  }

  Future<void> _cacheFarmMapTiles() async {
    final pts = <LatLng>[
      for (final p in _paddocks) ...p.outer,
    ];
    final bounds = MapTileCache.boundsForPaddocks(pts);
    if (bounds == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Load paddocks before caching map tiles')),
      );
      return;
    }

    _closeEndDrawer();

    const osmUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    const satUrl =
        'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
    final url = _satellite ? satUrl : osmUrl;

    if (!mounted) return;
    // Run prefetch inside the dialog so it always dismisses itself when done
    // (avoids a race where prefetch finishes before the route is pushed).
    final result = await showFadeDialog<({int done, bool cancelled})>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _CacheMapDialog(bounds: bounds, urlTemplate: url),
    );

    if (!mounted || result == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.cancelled
              ? 'Map cache cancelled (${result.done} tiles)'
              : 'Cached ${result.done} map tiles for farm area',
        ),
      ),
    );
  }

  // ---------- Map taps ----------

  void _onMapTap(TapPosition _, LatLng p) {
    if (_editorMode) {
      if (_tool == EditorTool.drawOuter || _tool == EditorTool.drawHole) {
        // Placement is via crosshair + Add — taps do not place points.
        return;
      }
      if (_tool == EditorTool.edit) {
        // Deselect live vertex on empty map tap; retarget paddock if hit.
        final hit = _hitTestPaddock(p);
        if (hit != null && hit != _editingIdx) {
          _selectPaddockForEdit(hit);
          return;
        }
        if (_vertexLiveMove) {
          setState(() => _clearVertexSelection(persist: true));
        }
        return;
      }
      // Browse: select mode or open for edit.
      final hit = _hitTestPaddock(p);
      if (_editorSelecting) {
        if (hit != null) {
          _editorToggleSelect(hit);
        }
        return;
      }
      if (hit != null) {
        _selectPaddockForEdit(hit);
      }
      return;
    }

    final hit = _hitTestPaddock(p);
    if (_navMode) return;
    if (_workListPicking) {
      if (hit != null) _toggleWorkListPaddockAt(hit);
      return;
    }
    if (hit != null) {
      setState(() {
        _suppressAutoPaddockSelect = false;
        _selectedIdx
          ..clear()
          ..add(hit);
      });
    } else {
      setState(() {
        _suppressAutoPaddockSelect = true;
        _selectedIdx.clear();
      });
    }
    _rebuildPaddockLayers();
  }

  Widget _buildVertexMarkers(Paddock p) {
    if (!_editorMode || _tool != EditorTool.edit || _editingIdx == null) {
      return const SizedBox.shrink();
    }
    final markers = <Marker>[];

    void addRing(List<LatLng> ring, int? holeIdx, Color color, Color selected) {
      for (var i = 0; i < ring.length; i++) {
        final isSel =
            _selectedHoleIdx == holeIdx && _selectedVertexIdx == i;
        markers.add(
          Marker(
            point: ring[i],
            width: 28,
            height: 28,
            alignment: Alignment.center,
            child: GestureDetector(
              onTap: () => _selectVertex(holeIdx: holeIdx, vertexIdx: i),
              child: Container(
                width: isSel ? 22 : 16,
                height: isSel ? 22 : 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSel ? selected : color,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 3),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }

    final scheme = Theme.of(context).colorScheme;
    addRing(p.outer, null, scheme.primary, scheme.tertiary);
    for (var h = 0; h < p.holes.length; h++) {
      addRing(p.holes[h], h, Colors.redAccent, Colors.orangeAccent);
    }
    return MarkerLayer(markers: markers);
  }

  Future<String?> _promptName(BuildContext context) async {
    final c = TextEditingController();
    return showFadeDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paddock name'),
        content: TextField(controller: c, decoration: const InputDecoration(hintText: 'eg. North 01')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  // Hit test which paddock contains the point (outer contains and not inside any hole)
  int? _hitTestPaddock(LatLng p) {
    for (int i = 0; i < _paddocks.length; i++) {
      final pd = _paddocks[i];
      if (pointInPolygon(p, pd.outer, pd.holes)) return i;
    }
    return null;
  }

  void _maybeAutoSelectPaddockFromGps() {
    if (_showingHistory || _editorMode || _navMode || _workListPicking) return;
    final pos = _dispPos ?? _currentPos;
    if (pos == null || _paddocks.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastAutoSelectMs < _autoSelectIntervalMs) return;
    _lastAutoSelectMs = nowMs;

    final hit = _hitTestPaddock(pos);
    if (hit == null) {
      _lastGpsInsidePaddockIdx = null;
      return;
    }

    if (_suppressAutoPaddockSelect) {
      if (_lastGpsInsidePaddockIdx == null) {
        _suppressAutoPaddockSelect = false;
      } else {
        _lastGpsInsidePaddockIdx = hit;
        return;
      }
    }

    _lastGpsInsidePaddockIdx = hit;
    if (_selectedIdx.length == 1 && _selectedIdx.first == hit) return;

    if (!mounted) return;
    setState(() {
      _selectedIdx
        ..clear()
        ..add(hit);
    });
    _rebuildPaddockLayers();
  }

  void _showCompletedJobOnMap(SavedJob job) {
    // Keep the force-committed live swath from the just-finished job. Rebuilding
    // from the simplified save path can drop rings (reversal/jump splitting) and
    // leave only the centreline visible.
    if (_committedSwathPolys.isEmpty && job.path.length >= 2) {
      _committedSwathPolys.addAll(_swathPolygonsForJob(job));
    }
    _swathCommittedNotifier.value = List<Polygon>.from(_committedSwathPolys);
    _swathLiveNotifier.value = null;
    _navPathCommittedNotifier.value = job.path.length >= 2
        ? Polyline(
            points: job.path,
            strokeWidth: 2.5,
            // Distinct from filled swath so both are visibly present.
            color: Colors.white.withOpacity(0.9),
          )
        : null;
    _navPathTailNotifier.value = null;
  }

  void _dismissCompletedJobSummary({bool clearMap = false}) {
    _completedJobSummary = null;
    _completedReadingCtrl?.dispose();
    _completedReadingCtrl = null;
    if (clearMap) _clearSwathDisplay();
  }

  void _prepareCompletedReadingField(LoadSession? load) {
    _completedReadingCtrl?.dispose();
    _completedReadingCtrl = null;
    if (load == null) return;
    _completedReadingCtrl = TextEditingController(
      text: load.expectedQtyNow > 0
          ? load.expectedQtyNow.toStringAsFixed(0)
          : '',
    );
  }

  Future<void> _saveCompletedJobReading() async {
    final ctrl = _completedReadingCtrl;
    final open = _openLoadSession;
    if (ctrl == null || open == null) return;
    final reading = double.tryParse(ctrl.text.trim());
    if (reading == null || reading < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid scale reading')),
      );
      return;
    }
    try {
      final updated = await LoadSessionStore.recordReading(reading: reading);
      await _refreshLoadSessionState();
      _updateSuggestedSpeedFromSession(updated);
      _prepareCompletedReadingField(_openLoadSession);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Reading saved · new start ${updated.currentQty.toStringAsFixed(0)} ${updated.unitLabel}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save reading: $e')),
      );
    }
  }

  void _maybeDismissCompletedSummaryOnGpsLeave() {
    if (_completedJobSummary == null || _dispPos == null || _paddocks.isEmpty) return;

    final job = _completedJobSummary!;
    final jobPaddockIndices = <int>[];
    for (int i = 0; i < _paddocks.length; i++) {
      if (job.paddockNames.contains(_paddocks[i].name)) {
        jobPaddockIndices.add(i);
      }
    }
    if (jobPaddockIndices.isEmpty) return;

    final hit = _hitTestPaddock(_dispPos!);
    if (hit != null && jobPaddockIndices.contains(hit)) return;

    setState(() {
      _dismissCompletedJobSummary(clearMap: true);
      _selectedIdx.clear();
      _suppressAutoPaddockSelect = false;
    });
  }

  Future<void> _finishDrawing() async {
    if (_tool == EditorTool.drawOuter) {
      if (_tempOuter.length < 3) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add at least 3 vertices')),
        );
        return;
      }
      final name = (_draftPaddockName != null && _draftPaddockName!.isNotEmpty)
          ? _draftPaddockName!
          : await _promptName(context);
      if (name == null || name.isEmpty) return;
      final outer = List<LatLng>.from(_tempOuter);
      final holes = <List<LatLng>>[];
      final area = _areaHa(outer, holes);
      final lp = _labelPoint(outer, holes);
      setState(() {
        _paddocks.add(
          Paddock(
            name: name,
            outer: outer,
            holes: holes,
            areaHa: area,
            labelPoint: lp,
          ),
        );
        _tempOuter.clear();
        _draftPaddockName = null;
        _editingIdx = _paddocks.length - 1;
        _clearVertexSelection();
        _tool = EditorTool.edit;
        _selectedIdx
          ..clear()
          ..add(_editingIdx!);
      });
      await _persistFarmJson(_buildFarmGeoJsonBytes());
      _rebuildPaddockLayers();
      return;
    }

    if (_tool == EditorTool.drawHole && _editingIdx != null) {
      if (_tempHole.length < 3) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add at least 3 vertices for a hole')),
        );
        return;
      }
      final idx = _editingIdx!;
      setState(() {
        _paddocks[idx].holes.add(List<LatLng>.from(_tempHole));
        _tempHole.clear();
        _tool = EditorTool.edit;
        _clearVertexSelection();
      });
      _recalcPaddock(idx);
      await _persistFarmJson(_buildFarmGeoJsonBytes());
    }
  }

  void _recalcPaddock(int idx) {
    final p = _paddocks[idx];
    final area = _areaHa(p.outer, p.holes);
    final lp = _labelPoint(p.outer, p.holes);
    _paddocks[idx] = Paddock(name: p.name, outer: p.outer, holes: p.holes, areaHa: area, labelPoint: lp);
    _rebuildPaddockLayers();
  }

  double _areaHa(List<LatLng> outer, List<List<LatLng>> holes) {
    double a = _ringAreaM2(outer);
    for (final h in holes) { a -= _ringAreaM2(h); }
    return (a / 10000.0).abs();
  }

  double _ringAreaM2(List<LatLng> ring) {
    if (ring.length < 3) return 0.0;
    final c = _centroid(ring);
    const R = 6371000.0;
    double toX(LatLng p) => (p.longitude - c.longitude) * (math.pi / 180.0) * R * math.cos(c.latitude * math.pi / 180.0);
    double toY(LatLng p) => (p.latitude  - c.latitude)  * (math.pi / 180.0) * R;
    double sum = 0.0;
    for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = toX(ring[i]), yi = toY(ring[i]);
      final xj = toX(ring[j]), yj = toY(ring[j]);
      sum += (xj * yi - xi * yj);
    }
    return 0.5 * sum.abs();
  }

  LatLng _centroid(List<LatLng> ring) {
    double x = 0, y = 0;
    for (final p in ring) { x += p.latitude; y += p.longitude; }
    return LatLng(x / ring.length, y / ring.length);
  }

  LatLng _labelPoint(List<LatLng> outer, List<List<LatLng>> holes) {
    return bestInteriorLabelPoint(outer, holes);
  }

  // ---------- Job flow ----------
  Future<void> _startNavigation() async {
    if (_selectedIdx.isEmpty) return;
    setState(() {
      _navMode = true;
      _workListPicking = false;
      _jobLockedPaddockIdx
        ..clear()
        ..addAll(_selectedIdx);
      _editorMode = false;
      _tool = EditorTool.browse;
      _tempOuter.clear();
      _tempHole.clear();
      _draftPaddockName = null;
      _editingIdx = null;
      _clearVertexSelection();
      _pointA = null;
      _pointB = null;
      _navLinesNotifier.value = [];
      _guidanceParallelLines = [];
      _lookAheadNotifier.value = null;
      _implementTracker.reset();
      _gpsRecordPath = [];
      _jobPath = [];
      _lastTravelBearingDeg = null;
      _speedDistanceM = 0.0;
      _lastSpeedFixTime = null;
      if (_currentPos != null) {
        _gpsRecordPath.add(_currentPos!);
        _rebuildJobPathFromGps();
      }
      _coverageDistanceCacheM = 0.0;
      _coverageDistanceCachePathLen = -1;
      _coverageDistanceCacheMs = 0;
      _currentSpeedKph = 0.0;
      _suggestedTargetSpeedKph = null;
      _lastSwathRecordBucket = null;
      _lastSpeedSampleBucket = null;
      _clearSwathDisplay();
      _showingHistory = false;
      _activeHistoryJobs = [];
      _completedJobSummary = null;
      _historySwathPolys.clear();
      _historyPathPolylines.clear();
      _histSelecting = false;
      _histSelected.clear();
      _jobStartTime = DateTime.now();
      _signedErrorNotifier.value = 0;
      _rotationMode = RotationMode.travelUp;
      _followGps = true;
    });
    _updateWakeLock();
    _setPipEnabled(true);
    _rebuildPaddockLayers();

    if (_mapReady && _dispPos != null) {
      final hdg = _tractorHeadingDeg();
      final p = _dispPos!;
      final latRad = p.latitude * math.pi / 180.0;
      final widthM = _toMeters(_width <= 0 ? 3.0 : _width);
      final acrossM = widthM * 3.0;
      final screenW = MediaQuery.of(context).size.width;
      final mpp0 = 156543.03392 * math.cos(latRad);
      final denom = (screenW * mpp0 / acrossM).clamp(1.0, 1e12);
      final z = math.log(denom) / math.ln2;
      _swoopCamera(
        center: p,
        zoom: z.clamp(5.0, 22.0),
        rotationDeg: hdg != null ? -hdg : null,
      );
    }
    if (_jobPath.isNotEmpty) _rebuildNavOverlays();
    _updateImplementGeometry();
    _updateLookAhead();
  }

  Future<void> _finishJob() async {
    if (_jobFinishInProgress) return;

    if (!_navMode || _jobStartTime == null || _jobPath.length < 2) {
      setState(() {
        _navMode = false;
        _jobLockedPaddockIdx.clear();
        _pointA = null;
        _pointB = null;
        _navLinesNotifier.value = [];
        _guidanceParallelLines.clear();
        _lookAheadNotifier.value = null;
      });
      _resetToMapDefaults();
      return;
    }

    _jobFinishInProgress = true;
    if (!mounted) return;
    showFadeDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Material(
          type: MaterialType.transparency,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
    );
    try {
      await Future<void>.delayed(Duration.zero);
      // Flush any uncommitted live tip into the display before leaving nav.
      _maybeCommitSwath(force: true);
      final end = DateTime.now();

      final savedPath = simplifySwathPath(
        _jobPath,
        minDistM: _jobSaveSimplifyMinDistM,
      );
      // Same paddock-gated simplified length used by the live coverage HUD.
      final pathDistanceM = _paddockGatedPathDistanceM(savedPath);

      final durHrs = end.difference(_jobStartTime!).inMilliseconds / 3600000.0;
      final avgKph = durHrs > 0 ? (_speedDistanceM / 1000.0) / durHrs : 0.0;

      final jobIdx = _jobAreaPaddockIndices()
          .where((i) => i >= 0 && i < _paddocks.length)
          .toList();
      final names = jobIdx.map((i) => _paddocks[i].name).toList()..sort();
      final totalHa = jobIdx.fold(0.0, (s, i) => s + _paddocks[i].areaHa);

      final n = await JobStore.nextSequenceForDay(end);
      final id = JobStore.dayTitle(end, n);

      final displayWidth = _currentWidthDisplay();
      final widthM = _toMeters(displayWidth);

      LatLng? weatherLoc = _dispPos ?? _currentPos;
      if (weatherLoc == null && savedPath.isNotEmpty) {
        weatherLoc = savedPath[savedPath.length ~/ 2];
      }
      if (weatherLoc == null && jobIdx.isNotEmpty) {
        weatherLoc = _paddocks[jobIdx.first].labelPoint;
      }
      JobWeather? weather;
      if (weatherLoc != null) {
        weather = await WeatherService.fetchForJob(
          location: weatherLoc,
          at: end,
        );
      }

      final job = SavedJob(
        id: id,
        startedAt: _jobStartTime!,
        endedAt: end,
        path: savedPath,
        paddockNames: names,
        totalHa: totalHa,
        avgSpeedKph: avgKph,
        swathWidthM: widthM,
        pathDistanceM: pathDistanceM,
        swathWidthSetting: displayWidth,
        unitsAtSave: _units,
        hasSavedSwathWidth: true,
        weather: weather,
      );

      await JobStore.save(job);

      final appliedHa = job.areaAppliedHaFor(widthM);
      await LoadSessionStore.attachJob(
        jobId: job.id,
        appliedHa: appliedHa,
        paddockHa: job.totalHa,
      );
      await _refreshLoadSessionState();
      await _markWorkListJobsComplete(names);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      setState(() {
        _navMode = false;
        _jobLockedPaddockIdx.clear();
        _pointA = null;
        _pointB = null;
        _navLinesNotifier.value = [];
        _guidanceParallelLines.clear();
        _lookAheadNotifier.value = null;
        _completedJobSummary = job;
        _prepareCompletedReadingField(_openLoadSession);
        _showCompletedJobOnMap(job);
        _invalidateJobSummariesCache();
      });
      _resetToMapDefaults();
    } catch (e) {
      if (mounted) {
        if (Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save job: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      _jobFinishInProgress = false;
    }
  }

  void _markA() {
    if (_dispPos == null) return;
    setState(() {
      _pointA = _dispPos;
      _pointB = null;
      _navLinesNotifier.value = [];
      _guidanceParallelLines = [];
      _signedErrorNotifier.value = 0;
    });
  }

  void _markB() {
    if (_dispPos == null || _pointA == null) return;
    final b = _dispPos!;
    setState(() => _pointB = b);
    _buildGuidance(_pointA!, b);
  }

  // ---------- UI: Drawer ----------
  Widget _buildDrawer() {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Drawer(
      child: SafeArea(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: Column(
              children: [
                TabBar(
                  controller: _drawerTabCtrl,
                  tabs: const [
                    Tab(text: 'History'),
                    Tab(text: 'Tool setup'),
                    Tab(text: 'Settings'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _drawerTabCtrl,
                    children: [
                      _historyTab(),
                      _toolSetupTab(),
                      _settingsTab(),
                    ],
                  ),
                ),
              ],
            ),
        ),
      ),
    );
  }

  Widget _toolSetupTab() {
    return ToolSetupTab(
      units: _units,
      lenUnit: _lenUnit(),
      dimensions: _toolDims,
      gpsSmoothness: _gpsSmoothness,
      smoothnessHint: _gpsSmoothnessLabel(),
      presets: _toolPresets,
      selectedPresetName: _selectedToolPresetName,
      onUnitsChanged: (u) {
        setState(() => _units = u);
        _rebuildPaddockLayers();
      },
      onDimensionsChanged: (d) {
        setState(() {
          _toolDims = d;
          _selectedToolPresetName = null;
        });
        _updateImplementGeometry();
      },
      onGpsSmoothnessChanged: (v) {
        setState(() {
          _gpsSmoothness = v;
          _gpsSmoother.smoothness = v;
          if (v <= 0) {
            _gpsSmoother.snapToTarget();
            _syncDisplayFromSmoother();
            _gpsSmoothTicker?.stop();
            _applyDisplayCamera();
            _notifyDisplayPosition();
          } else {
            _ensureGpsSmoothTickerRunning();
          }
        });
        _savePrefs();
      },
      onPresetSelected: (preset) {
        setState(() {
          _selectedToolPresetName = preset?.name;
          if (preset != null) {
            _toolDims = preset.dimensions;
            _implementTracker.reset();
          }
        });
        _updateImplementGeometry();
        _savePrefs();
      },
      onSavePreset: (name) async {
        await ToolPresetStore.upsert(ToolPreset(name: name, dimensions: _toolDims));
        if (!mounted) return;
        setState(() => _selectedToolPresetName = name);
        _toolPresets = await ToolPresetStore.list();
        if (mounted) setState(() {});
        _savePrefs();
      },
      onDeletePreset: (name) async {
        await ToolPresetStore.delete(name);
        if (!mounted) return;
        setState(() {
          if (_selectedToolPresetName?.toLowerCase() == name.toLowerCase()) {
            _selectedToolPresetName = null;
          }
        });
        _toolPresets = await ToolPresetStore.list();
        if (mounted) setState(() {});
        _savePrefs();
      },
      onSave: _savePrefs,
    );
  }

  Widget _settingsTab() {
    return ListenableBuilder(
      listenable: _gpsInput,
      builder: (context, _) {
        return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const ListTile(title: Text('GPS input', style: TextStyle(fontWeight: FontWeight.bold))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<GpsInputMode>(
            value: _gpsInput.mode,
            decoration: const InputDecoration(
              labelText: 'Source',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: GpsInputMode.values
                .map((m) => DropdownMenuItem(value: m, child: Text(m.label)))
                .toList(),
            onChanged: (m) async {
              if (m == null) return;
              await _gpsInput.setMode(m);
              await _savePrefs();
            },
          ),
        ),
        if (_gpsInput.mode != GpsInputMode.device)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Close GPS Connector while using in-app USB — only one app can own the dongle.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ListTile(
          title: Text(_gpsInput.statusMessage),
          subtitle: Text(_gpsQualitySubtitle()),
          trailing: IconButton(
            tooltip: 'Reconnect',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _gpsInput.reconnect();
            },
          ),
        ),
        if (_gpsInput.activeSource != GpsActiveSource.none)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: _gpsQualityChip(
                    'Sats',
                    _gpsInput.satellites?.toString() ?? '—',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _gpsQualityChip(
                    'Accuracy',
                    _gpsInput.accuracyM == null
                        ? '—'
                        : '±${_gpsInput.accuracyM!.toStringAsFixed(1)} m',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _gpsQualityChip(
                    'Rate',
                    _gpsInput.fixHz <= 0
                        ? '—'
                        : '${_gpsInput.fixHz.toStringAsFixed(1)} Hz',
                  ),
                ),
              ],
            ),
          ),
        const Divider(),

        const ListTile(title: Text('Map & Tiles', style: TextStyle(fontWeight: FontWeight.bold))),
        SwitchListTile(
          title: const Text('Satellite view (Esri)'),
          value: _satellite,
          onChanged: (v) {
            setState(() => _satellite = v);
            _savePrefs();
          },
        ),
        const Divider(),

        const ListTile(title: Text('Appearance', style: TextStyle(fontWeight: FontWeight.bold))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: DropdownButtonFormField<ThemeMode>(
            value: widget.themeController.mode,
            decoration: const InputDecoration(
              labelText: 'Theme',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: ThemeMode.values
                .map((m) => DropdownMenuItem(
                      value: m,
                      child: Text(ThemeController.label(m)),
                    ))
                .toList(),
            onChanged: (m) async {
              if (m == null) return;
              await widget.themeController.setMode(m);
              if (mounted) setState(() {});
              await _savePrefs();
            },
          ),
        ),
        const Divider(),

        const ListTile(title: Text('Farm JSON', style: TextStyle(fontWeight: FontWeight.bold))),
        ListTile(
          leading: const Icon(Icons.upload_file),
          title: const Text('Load farm JSON'),
          subtitle: Text(
            _paddocks.isEmpty
                ? (_persistedJsonPath == null ? 'None loaded' : 'Loaded (persisted): ${_paddocks.length} paddocks')
                : 'Loaded: ${_paddocks.length} paddocks',
          ),
          onTap: _loadFarmJson,
        ),
        ListTile(
          leading: const Icon(Icons.download_for_offline_outlined),
          title: const Text('Cache farm map'),
          subtitle: Text(
            _paddocks.isEmpty
                ? 'Load paddocks first'
                : 'Download map tiles covering ${_paddocks.length} paddocks',
          ),
          enabled: _paddocks.isNotEmpty,
          onTap: _cacheFarmMapTiles,
        ),

        const Divider(),
        ListTile(
          leading: const Icon(Icons.edit_note),
          title: const Text('Edit paddocks'),
          subtitle: const Text('Create, edit, or delete paddock boundaries'),
          onTap: () {
            Navigator.of(context).maybePop();
            _enterEditorMode();
          },
        ),
        const Divider(),

        const ListTile(title: Text('Backup & Restore', style: TextStyle(fontWeight: FontWeight.bold))),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('Create backup'),
          subtitle: const Text('Saves to Downloads as PasturePath backup <date-time>'),
          onTap: _createBackup,
        ),
        ListTile(
          leading: const Icon(Icons.restore_outlined),
          title: const Text('Restore backup'),
          subtitle: const Text('Replace current data from a backup file'),
          onTap: _restoreBackup,
        ),
        FutureBuilder<List<BackupInfo>>(
          future: _backupsFutureOrLoad(),
          builder: (context, snap) {
            final backups = snap.data ?? const [];
            if (backups.isEmpty) return const SizedBox.shrink();
            final latest = backups.first;
            final when = latest.createdAt;
            final label = '${when.day.toString().padLeft(2, '0')}/${when.month.toString().padLeft(2, '0')}/${when.year} '
                '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
            return ListTile(
              dense: true,
              title: Text('Latest backup: $label'),
              subtitle: Text('${latest.jobCount} job(s)${latest.hasFarmJson ? ', farm map' : ''}'),
              trailing: TextButton(
                onPressed: () async {
                  final ok = await showFadeDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Restore latest backup?'),
                      content: Text(
                        'Restore the backup from $label?\n\n'
                        'This will replace your current jobs, farm map, and settings.',
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  try {
                    await BackupStore.restoreBackup(latest.path);
                    await _applyRestoredData();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Backup restored')),
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Restore failed: $e')),
                    );
                  }
                },
                child: const Text('Restore'),
              ),
            );
          },
        ),
        const Divider(),
        const ListTile(title: Text('About', style: TextStyle(fontWeight: FontWeight.bold))),
        _AppVersionTile(),
      ],
        );
      },
    );
  }

  Future<List<BackupInfo>> _backupsFutureOrLoad() {
    return _backupsFuture ??= BackupStore.listBackups();
  }

  void _invalidateBackupsFuture() {
    _backupsFuture = null;
  }

  String _gpsQualitySubtitle() {
    final active = switch (_gpsInput.activeSource) {
      GpsActiveSource.usb => 'Active: USB',
      GpsActiveSource.device => 'Active: device GPS',
      GpsActiveSource.none => 'Active: none',
    };
    final hint = _gpsInput.connectionHint;
    if (hint != null && hint.isNotEmpty) return '$active · $hint';
    return active;
  }

  Widget _gpsQualityChip(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDayHeader(DateTime day) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${weekdays[day.weekday - 1]}, ${day.day} ${months[day.month - 1]} ${day.year}';
  }

  String _jobSwathWidthText(SavedJob job) {
    if (job.hasSavedSwathWidth && job.swathWidthSetting != null && job.unitsAtSave != null) {
      final unit = job.unitsAtSave == 'feet' ? 'ft' : 'm';
      return '${job.swathWidthSetting!.toStringAsFixed(1)} $unit';
    }
    final m = _jobSwathWidthM(job);
    if (job.hasSavedSwathWidth) {
      return _units == 'feet'
          ? '${(m * 3.280839895).toStringAsFixed(1)} ft'
          : '${m.toStringAsFixed(1)} m';
    }
    return _units == 'feet'
        ? '${_currentWidthDisplay().toStringAsFixed(1)} ft'
        : '${_currentWidthDisplay().toStringAsFixed(1)} m';
  }

  double _summaryAreaAppliedHa(JobFileSummary job) =>
      job.areaAppliedHaFor(_currentSwathWidthM());

  double _summaryCoveragePercent(JobFileSummary job) =>
      job.coveragePercentFor(_currentSwathWidthM());

  void _invalidateJobSummariesCache() {
    _historyListGeneration++;
    _jobSummariesFuture = JobStore.listJobSummaries();
  }

  Future<List<JobFileSummary>> _jobSummariesFutureOrLoad() {
    return _jobSummariesFuture ??= JobStore.listJobSummaries();
  }

  String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _historyTab() {
    return FutureBuilder<List<JobFileSummary>>(
      key: ValueKey(_historyListGeneration),
      future: _jobSummariesFutureOrLoad(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snap.data!;
        if (rows.isEmpty) return const Center(child: Text('No jobs saved yet.'));

        final byDay = <DateTime, List<JobFileSummary>>{};
        for (final row in rows) {
          final day = DateTime(row.startedAt.year, row.startedAt.month, row.startedAt.day);
          byDay.putIfAbsent(day, () => []).add(row);
        }
        final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));

        double selectedTotalHa = 0;
        double selectedAppliedHa = 0;
        for (final row in rows) {
          if (_histSelected.contains(row.filePath)) {
            selectedTotalHa += row.totalHa;
            selectedAppliedHa += row.areaAppliedHaFor(_currentSwathWidthM());
          }
        }
        final selectedCoverage = selectedTotalHa > 0
            ? (selectedAppliedHa / selectedTotalHa * 100).clamp(0, double.infinity)
            : 0.0;

        return Column(
          children: [
            if (_histSelecting)
              Material(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_histSelected.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            'Area: ${_areaText(selectedTotalHa)}  •  Applied: ${_areaText(selectedAppliedHa)}  •  ${selectedCoverage.toStringAsFixed(0)}%',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                        ),
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          Text('${_histSelected.length} selected'),
                      IconButton(
                        tooltip: 'Show on map',
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                        padding: EdgeInsets.zero,
                        onPressed: _histSelected.isEmpty ? null : () async {
                          await _showHistoryJobsFromPaths(_histSelected.toList());
                        },
                        icon: const Icon(Icons.map_outlined),
                      ),
                      IconButton(
                        tooltip: 'Export GPX',
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                        padding: EdgeInsets.zero,
                        onPressed: _histSelected.isEmpty ? null : () async {
                          final path = await JobStore.exportGpx(_histSelected.toList());
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported GPX: ${path.split('/').last}')));
                          await JobStore.shareFile(path);
                        },
                        icon: const Icon(Icons.file_download_outlined),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                        padding: EdgeInsets.zero,
                        onPressed: _histSelected.isEmpty ? null : () async {
                          final ok = await showFadeDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete selected jobs?'),
                              content: Text('Delete ${_histSelected.length} job(s) permanently?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                              ],
                            ),
                          );
                          if (ok == true) {
                            for (final f in _histSelected) { await JobStore.delete(f); }
                            if (!mounted) return;
                            setState(() {
                              _histSelecting = false;
                              _histSelected.clear();
                              _invalidateJobSummariesCache();
                            });
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deleted')));
                          }
                        },
                        icon: const Icon(Icons.delete),
                      ),
                      TextButton(onPressed: () => setState(() { _histSelecting = false; _histSelected.clear(); }), child: const Text('Clear')),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: days.length,
                itemBuilder: (context, di) {
                  final day = days[di];
                  final dayJobs = byDay[day]!;
                  final dayPaths = dayJobs.map((e) => e.filePath).toSet();
                  final allDaySelected = dayPaths.every((p) => _histSelected.contains(p));
                  final expanded = _histExpandedDays.contains(day);
                  final dayTotalHa = dayJobs.fold(0.0, (s, e) => s + e.totalHa);
                  final dayAppliedHa = dayJobs.fold(
                    0.0,
                    (s, e) => s + _summaryAreaAppliedHa(e),
                  );
                  final dayAvgCoverage = dayTotalHa > 0
                      ? (dayAppliedHa / dayTotalHa * 100).clamp(0, double.infinity)
                      : 0.0;
                  double rateSum = 0;
                  var rateCount = 0;
                  var dayRateUnit = 'kg';
                  for (final j in dayJobs) {
                    final p = _productStatsByJobId[j.id];
                    if (p == null) continue;
                    rateSum += p.ratePerHa;
                    rateCount++;
                    dayRateUnit = p.recordUnitLabel;
                  }
                  final dayAvgRate = rateCount > 0 ? rateSum / rateCount : null;
                  final dayWeather = dayJobs
                      .map((e) => e.weather)
                      .whereType<JobWeather>()
                      .where((w) => w.shortLabel != '—')
                      .map((w) => w.shortLabel)
                      .firstOrNull;

                  void toggleDaySelection() {
                    setState(() {
                      if (allDaySelected) {
                        for (final p in dayPaths) {
                          _histSelected.remove(p);
                        }
                      } else {
                        _histSelected.addAll(dayPaths);
                      }
                    });
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Material(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                        child: InkWell(
                          onLongPress: () {
                            setState(() {
                              _histSelecting = true;
                              if (!allDaySelected) {
                                _histSelected.addAll(dayPaths);
                              }
                            });
                          },
                          onTap: () {
                            if (_histSelecting) {
                              toggleDaySelection();
                              return;
                            }
                            _showHistoryJobsFromPaths(
                              dayJobs.map((e) => e.filePath).toList(),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                            child: Row(
                              children: [
                                if (_histSelecting)
                                  Checkbox(
                                    value: allDaySelected,
                                    tristate: true,
                                    onChanged: (_) => toggleDaySelection(),
                                  ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _formatDayHeader(day),
                                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        [
                                          '${dayJobs.length} job${dayJobs.length == 1 ? '' : 's'}',
                                          _areaText(dayTotalHa),
                                          '${dayAvgCoverage.toStringAsFixed(0)}% avg',
                                          if (dayAvgRate != null)
                                            '${dayAvgRate.toStringAsFixed(0)} ${dayRateUnit}/ha avg',
                                          if (dayWeather != null) dayWeather,
                                        ].join(' · '),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: expanded ? 'Collapse jobs' : 'Expand jobs',
                                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                                  onPressed: () {
                                    setState(() {
                                      if (expanded) {
                                        _histExpandedDays.remove(day);
                                      } else {
                                        _histExpandedDays.add(day);
                                      }
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (expanded)
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            headingRowHeight: 36,
                            dataRowMinHeight: 40,
                            dataRowMaxHeight: 52,
                            columnSpacing: 16,
                            columns: const [
                              DataColumn(label: Text('Paddock', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                              DataColumn(label: Text('Area', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                              DataColumn(label: Text('Applied', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                              DataColumn(label: Text('Coverage', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                              DataColumn(label: Text('Rate', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                              DataColumn(label: Text('Time', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                            ],
                            rows: dayJobs.map((entry) {
                              final j = entry;
                              final selected = _histSelected.contains(entry.filePath);
                              final paddock = j.paddockNames.join(', ');
                              final product = _productStatsByJobId[j.id];
                              return DataRow(
                                selected: selected,
                                onSelectChanged: _histSelecting ? (_) {
                                  setState(() {
                                    if (selected) {
                                      _histSelected.remove(entry.filePath);
                                    } else {
                                      _histSelected.add(entry.filePath);
                                    }
                                  });
                                } : null,
                                cells: [
                                  DataCell(
                                    Text(paddock, style: const TextStyle(fontSize: 12)),
                                    onTap: () async {
                                      if (_histSelecting) {
                                        setState(() {
                                          if (selected) {
                                            _histSelected.remove(entry.filePath);
                                          } else {
                                            _histSelected.add(entry.filePath);
                                          }
                                        });
                                        return;
                                      }
                                      await _showHistoryJobsFromPaths([entry.filePath]);
                                    },
                                    onLongPress: () {
                                      setState(() {
                                        _histSelecting = true;
                                        _histSelected.add(entry.filePath);
                                      });
                                    },
                                  ),
                                  DataCell(Text(_areaText(j.totalHa), style: const TextStyle(fontSize: 12))),
                                  DataCell(Text(_areaText(_summaryAreaAppliedHa(j)), style: const TextStyle(fontSize: 12))),
                                  DataCell(Text('${_summaryCoveragePercent(j).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 12))),
                                  DataCell(Text(
                                    product?.historyLabel ?? '—',
                                    style: const TextStyle(fontSize: 12),
                                  )),
                                  DataCell(Text(_formatTime(j.startedAt), style: const TextStyle(fontSize: 12))),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      const Divider(height: 1),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _showHistoryJobs(List<SavedJob> jobs) {
    if (jobs.isEmpty) return;
    final swaths = <Polygon>[];
    final paths = <Polyline>[];
    for (final job in jobs) {
      swaths.addAll(_swathPolygonsForJob(job));
      if (job.path.length >= 2) {
        paths.add(Polyline(
          points: job.path,
          strokeWidth: 2.5,
          color: _swathColor.withOpacity(_swathOpacity),
        ));
      }
    }

    setState(() {
      _showingHistory = true;
      _activeHistoryJobs = List.from(jobs);
      _dismissCompletedJobSummary();
      _clearSwathDisplay();
      _historySwathPolys
        ..clear()
        ..addAll(swaths);
      _historyPathPolylines
        ..clear()
        ..addAll(paths);
      _navMode = false;
      _workListPicking = false;
      _jobLockedPaddockIdx.clear();
      _selectedIdx.clear();
      _navLinesNotifier.value = [];
      _guidanceParallelLines.clear();
      _lookAheadNotifier.value = null;
      _followGps = false;
    });

    final allPts = jobs.expand((j) => j.path).toList();
    if (_mapReady && allPts.isNotEmpty) {
      final lats = allPts.map((e) => e.latitude).toList();
      final lngs = allPts.map((e) => e.longitude).toList();
      _mapController.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds(
          LatLng(lats.reduce(math.min), lngs.reduce(math.min)),
          LatLng(lats.reduce(math.max), lngs.reduce(math.max)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 180),
      ));
    }
  }

  void _exitHistory() {
    setState(() {
      _showingHistory = false;
      _activeHistoryJobs = [];
      _historySwathPolys.clear();
      _historyPathPolylines.clear();
    });
    _resetToMapDefaults();
  }

  Widget _completedJobSummaryPanel() {
    final j = _completedJobSummary!;
    final scheme = Theme.of(context).colorScheme;
    final appliedHa = _jobAreaAppliedHa(j);
    final load = _openLoadSession;
    final closedStats = _productStatsByJobId[j.id];
    final readingCtrl = _completedReadingCtrl;

    Widget stat(String label, String value) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSecondaryContainer.withOpacity(0.75),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: scheme.onSecondaryContainer,
            ),
          ),
        ],
      );
    }

    return Material(
      elevation: 8,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
      color: scheme.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.check_circle, color: scheme.onSecondaryContainer, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Job complete',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Dismiss',
                    icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
                    onPressed: () => setState(_dismissCompletedJobSummary),
                  ),
                ],
              ),
              Text(
                j.paddockNames.join(', '),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: scheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  stat('Area', _areaText(j.totalHa)),
                  stat('Applied', _areaText(appliedHa)),
                  stat('Coverage', '${_jobCoveragePercent(j).toStringAsFixed(0)}%'),
                  stat('Avg speed', '${j.avgSpeedKph.toStringAsFixed(1)} km/h'),
                  if (_suggestedTargetSpeedKph != null)
                    stat(
                      'Target speed',
                      '${_suggestedTargetSpeedKph!.toStringAsFixed(1)} km/h',
                    ),
                  if (closedStats != null)
                    stat('Rate', closedStats.historyLabel),
                  if (j.weather != null && j.weather!.shortLabel != '—')
                    stat('Weather', j.weather!.shortLabel),
                ],
              ),
              if (load != null) ...[
                const SizedBox(height: 10),
                Text(
                  '${load.displayName} · expect ${load.expectedQtyNow.toStringAsFixed(0)} ${load.unitLabel} · target ${load.primaryTargetRateLabel}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                if (readingCtrl != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: readingCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _saveCompletedJobReading(),
                          style: TextStyle(
                            color: scheme.onSecondaryContainer,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: 'Scale reading (${load.unitLabel})',
                            labelStyle: TextStyle(
                              color: scheme.onSecondaryContainer.withOpacity(0.75),
                            ),
                            hintText: 'Optional',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _saveCompletedJobReading,
                        child: const Text('Save reading'),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _historyJobPanel() {
    return _HistoryJobPanel(
      jobs: _activeHistoryJobs,
      paddocks: _paddocks,
      mapController: _mapController,
      mapReady: _mapReady,
      areaText: _areaText,
      jobSwathWidthText: _jobSwathWidthText,
      jobAreaAppliedHa: _jobAreaAppliedHa,
      jobCoveragePercent: _jobCoveragePercent,
      jobSwathWidthM: _jobSwathWidthM,
      formatDayHeader: _formatDayHeader,
      formatTime: _formatTime,
      productStatsByJobId: _productStatsByJobId,
    );
  }

  Future<void> _showPaddockHistory(String paddockName) async {
    final summaries = await JobStore.listJobSummaries();
    final allRows = summaries
        .where((j) => j.paddockNames.contains(paddockName))
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    double paddockAreaHa = 0;
    for (final p in _paddocks) {
      if (p.name == paddockName) {
        paddockAreaHa = p.areaHa;
        break;
      }
    }

    if (!mounted) return;
    // ignore: use_build_context_synchronously
    showFadeModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        if (allRows.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No history for this paddock.'),
          );
        }

        DateTime? rangeStart;
        DateTime? rangeEnd;
        final selected = <String>{};
        var selecting = false;
        final swathM = _currentSwathWidthM();
        final productStats = _productStatsByJobId;
        final areaText = _areaText;
        final formatDay = _formatDayHeader;

        double shareFor(JobFileSummary j) => paddockJobShare(
              paddockNames: j.paddockNames,
              paddockName: paddockName,
              jobTotalHa: j.totalHa,
              paddockAreaHa: paddockAreaHa,
            );

        double appliedFor(JobFileSummary j) =>
            j.areaAppliedHaFor(swathM) * shareFor(j);

        double coverageFor(JobFileSummary j) {
          final area = paddockAreaHa > 0 ? paddockAreaHa : j.totalHa;
          if (area <= 0) return 0;
          return (appliedFor(j) / area * 100).clamp(0, double.infinity);
        }

        bool inRange(JobFileSummary j) {
          final day = DateTime(
            j.startedAt.year,
            j.startedAt.month,
            j.startedAt.day,
          );
          if (rangeStart != null && day.isBefore(rangeStart!)) return false;
          if (rangeEnd != null && day.isAfter(rangeEnd!)) return false;
          return true;
        }

        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final rows = allRows.where(inRange).toList();
            final tallyRows = selecting && selected.isNotEmpty
                ? rows.where((j) => selected.contains(j.filePath)).toList()
                : rows;

            final totalApplied =
                tallyRows.fold(0.0, (s, j) => s + appliedFor(j));
            final coverageArea = paddockAreaHa > 0 ? paddockAreaHa : 0.0;
            final coveragePct = coverageArea > 0
                ? (totalApplied / coverageArea * 100).clamp(0, double.infinity)
                : 0.0;

            // Product totals keyed by name + record unit.
            final productTotals = <String, ({double amount, String unit, String? name})>{};
            for (final j in tallyRows) {
              final stats = productStats[j.id];
              if (stats == null) continue;
              final share = shareFor(j);
              if (share <= 0) continue;
              final key =
                  '${stats.displayName}|${stats.recordUnitLabel}';
              final prev = productTotals[key];
              final amt = stats.amount * share;
              if (prev == null) {
                productTotals[key] = (
                  amount: amt,
                  unit: stats.recordUnitLabel,
                  name: stats.productName,
                );
              } else {
                productTotals[key] = (
                  amount: prev.amount + amt,
                  unit: prev.unit,
                  name: prev.name,
                );
              }
            }

            Future<void> pickStart() async {
              final picked = await showDatePicker(
                context: ctx,
                initialDate: rangeStart ?? allRows.first.startedAt,
                firstDate: DateTime(
                  allRows.last.startedAt.year,
                  allRows.last.startedAt.month,
                  allRows.last.startedAt.day,
                ),
                lastDate: DateTime(
                  allRows.first.startedAt.year,
                  allRows.first.startedAt.month,
                  allRows.first.startedAt.day,
                ),
              );
              if (picked == null) return;
              setLocal(() {
                rangeStart = DateTime(picked.year, picked.month, picked.day);
                if (rangeEnd != null && rangeEnd!.isBefore(rangeStart!)) {
                  rangeEnd = rangeStart;
                }
              });
            }

            Future<void> pickEnd() async {
              final first = rangeStart ??
                  DateTime(
                    allRows.last.startedAt.year,
                    allRows.last.startedAt.month,
                    allRows.last.startedAt.day,
                  );
              final picked = await showDatePicker(
                context: ctx,
                initialDate: rangeEnd ?? (rangeStart ?? allRows.first.startedAt),
                firstDate: first,
                lastDate: DateTime(
                  allRows.first.startedAt.year,
                  allRows.first.startedAt.month,
                  allRows.first.startedAt.day,
                ),
              );
              if (picked == null) return;
              setLocal(() {
                rangeEnd = DateTime(picked.year, picked.month, picked.day);
              });
            }

            return LayoutBuilder(
              builder: (ctx, constraints) {
                final h = constraints.maxHeight.isFinite &&
                        constraints.maxHeight > 0
                    ? constraints.maxHeight
                    : MediaQuery.of(ctx).size.height * 0.7;
                return SizedBox(
                  height: h,
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            paddockName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 18,
                            ),
                          ),
                        ),
                        if (selecting)
                          TextButton(
                            onPressed: () => setLocal(() {
                              selecting = false;
                              selected.clear();
                            }),
                            child: const Text('Done'),
                          )
                        else
                          TextButton(
                            onPressed: () => setLocal(() => selecting = true),
                            child: const Text('Select'),
                          ),
                      ],
                    ),
                  ),
                  if (paddockAreaHa > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        'Paddock area ${areaText(paddockAreaHa)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ActionChip(
                          label: Text(
                            rangeStart == null
                                ? 'From date'
                                : 'From ${formatDay(rangeStart!)}',
                          ),
                          onPressed: pickStart,
                        ),
                        ActionChip(
                          label: Text(
                            rangeEnd == null
                                ? 'To date'
                                : 'To ${formatDay(rangeEnd!)}',
                          ),
                          onPressed: pickEnd,
                        ),
                        if (rangeStart != null || rangeEnd != null)
                          TextButton(
                            onPressed: () => setLocal(() {
                              rangeStart = null;
                              rangeEnd = null;
                            }),
                            child: const Text('Clear dates'),
                          ),
                      ],
                    ),
                  ),
                  Material(
                    color: Theme.of(ctx)
                        .colorScheme
                        .surfaceContainerHighest
                        .withOpacity(0.55),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selecting && selected.isNotEmpty
                                ? '${selected.length} selected'
                                : '${rows.length} job${rows.length == 1 ? '' : 's'}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Applied ${areaText(totalApplied)}'
                            '${coverageArea > 0 ? '  ·  ${coveragePct.toStringAsFixed(0)}% of paddock' : ''}',
                            style: const TextStyle(fontSize: 13),
                          ),
                          if (productTotals.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            ...productTotals.values.map((p) {
                              final rate = paddockAreaHa > 0
                                  ? p.amount / paddockAreaHa
                                  : 0.0;
                              final label = (p.name != null &&
                                      p.name!.trim().isNotEmpty)
                                  ? p.name!
                                  : 'Product';
                              return Text(
                                '$label  ${rate.toStringAsFixed(0)} ${p.unit}/ha · ${p.amount.toStringAsFixed(0)} ${p.unit}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              );
                            }),
                          ],
                          if (selecting && selected.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 4,
                              children: [
                                IconButton(
                                  tooltip: 'Show on map',
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _showHistoryJobsFromPaths(
                                      selected.toList(),
                                    );
                                  },
                                  icon: const Icon(Icons.map_outlined),
                                ),
                                TextButton(
                                  onPressed: () => setLocal(() {
                                    selected
                                      ..clear()
                                      ..addAll(rows.map((e) => e.filePath));
                                  }),
                                  child: const Text('All'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      setLocal(() => selected.clear()),
                                  child: const Text('None'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: rows.isEmpty
                        ? const Center(child: Text('No jobs in this date range.'))
                        : ListView.separated(
                            itemCount: rows.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final j = rows[i];
                              final isSel = selected.contains(j.filePath);
                              final product = productStats[j.id];
                              final day = DateTime(
                                j.startedAt.year,
                                j.startedAt.month,
                                j.startedAt.day,
                              );
                              return ListTile(
                                leading: selecting
                                    ? Checkbox(
                                        value: isSel,
                                        onChanged: (_) => setLocal(() {
                                          if (isSel) {
                                            selected.remove(j.filePath);
                                          } else {
                                            selected.add(j.filePath);
                                          }
                                        }),
                                      )
                                    : const Icon(Icons.route),
                                title: Text(
                                  '${formatDay(day)}  ${_formatTime(j.startedAt)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                  ),
                                ),
                                subtitle: Text(
                                  [
                                    'Applied ${areaText(appliedFor(j))}',
                                    '${coverageFor(j).toStringAsFixed(0)}%',
                                    if (j.paddockNames.length > 1)
                                      'share of ${j.paddockNames.length} paddocks',
                                    if (product != null) product.historyLabel,
                                  ].join('  ·  '),
                                ),
                                onTap: () {
                                  if (selecting) {
                                    setLocal(() {
                                      if (isSel) {
                                        selected.remove(j.filePath);
                                      } else {
                                        selected.add(j.filePath);
                                      }
                                    });
                                    return;
                                  }
                                  Navigator.pop(ctx);
                                  _showHistoryJobsFromPaths([j.filePath]);
                                },
                                onLongPress: () => setLocal(() {
                                  selecting = true;
                                  selected.add(j.filePath);
                                }),
                              );
                            },
                          ),
                  ),
                ],
              ),
                );
              },
            );
          },
        );
      },
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    if (_navMode && _inPipMode) {
      return Material(
        type: MaterialType.transparency,
        color: Colors.black,
        child: Center(
          child: ValueListenableBuilder<double>(
            valueListenable: _signedErrorNotifier,
            builder: (context, signedErrorM, _) => _ErrorChevronHud(
              signedErrorM: signedErrorM,
              chevronsPerSide: 2,
              controller: _chevCtrl,
              rowWidthMeters: _toMeters(_width <= 0 ? 3.0 : _width),
              pipMode: true,
            ),
          ),
        ),
      );
    }

    final safe = MediaQuery.of(context).padding;
    final startCenter = _dispPos ?? _currentPos ?? const LatLng(-37.6710, 175.6860);

    // Cursor marker — driven by notifier for 60 fps without rebuilding the whole map
    Widget gpsMarkerLayer = const SizedBox.shrink();
    if (!_showingHistory) {
      gpsMarkerLayer = ListenableBuilder(
        listenable: Listenable.merge([
          _dispPosNotifier,
          _dispHeadingNotifier,
        ]),
        builder: (context, _) {
          final pos = _dispPosNotifier.value;
          if (pos == null) return const SizedBox.shrink();
          const iconSize = 28.0;
          return MarkerLayer(
            markers: [
              Marker(
                point: pos,
                width: iconSize,
                height: iconSize,
                alignment: Alignment.center,
                child: NavigationArrowIcon(
                  size: iconSize,
                  headingDeg: _dispHeadingNotifier.value,
                ),
              ),
            ],
          );
        },
      );
    }

    // A / B guidance points in nav mode
    final navAbMarkers = <Marker>[];
    if (_navMode) {
      if (_pointA != null) {
        navAbMarkers.add(Marker(
          point: _pointA!,
          width: 24,
          height: 24,
          alignment: Alignment.center,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.green.shade600,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
            ),
          ),
        ));
      }
      if (_pointB != null) {
        navAbMarkers.add(Marker(
          point: _pointB!,
          width: 24,
          height: 24,
          alignment: Alignment.center,
          child: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _guidanceColor.withOpacity(0.95),
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
            ),
          ),
        ));
      }
    }

    // Dotted A→B preview while B is not yet placed
    Widget abPreviewLayer = const SizedBox.shrink();
    if (_navMode) {
      abPreviewLayer = ListenableBuilder(
        listenable: _dispPosNotifier,
        builder: (context, _) {
          if (_pointA == null || _pointB != null) return const SizedBox.shrink();
          final pos = _dispPosNotifier.value;
          if (pos == null) return const SizedBox.shrink();
          return PolylineLayer(
            polylines: [
              Polyline(
                points: [pos, _pointA!],
                color: _guidanceColor.withOpacity(0.85),
                strokeWidth: 3.5,
                isDotted: true,
              ),
            ],
          );
        },
      );
    }

    // Job selection summary + paddock name for history
    final double totalHa = _selectedIdx.fold(0.0, (s, i) => s + _paddocks[i].areaHa);
    final List<String> selectedNames = _selectedIdx.map((i) => _paddocks[i].name).toList()..sort();
    final String? singleSelectedName = _selectedIdx.length == 1 ? _paddocks[_selectedIdx.first].name : null;
    const navDashboardContentHeight = 58.0;
    const navErrorHudHeight = 48.0;
    final navTopInset = _navMode
        ? safe.top +
            navDashboardContentHeight +
            ((_pointA != null && _pointB != null) ? navErrorHudHeight : 0.0)
        : 0.0;

    final topChromeInset = _navMode
        ? navTopInset + _fabEdge
        : safe.top + _fabEdge + _fabSecondaryDiameter + _fabGap;

    return PopScope(
      // Always intercept so we can close the drawer even if MapScreen
      // hasn't rebuilt since it opened. Idle → SystemNavigator.pop.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final handled = await _handleSystemBack();
        if (!handled && mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
      key: _scaffoldKey,
      appBar: null,
      endDrawer: _buildDrawer(),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: startCenter,
              initialZoom: 16.0,
              onTap: _onMapTap,
              onLongPress: (tp, latlng) {
                if (_editorMode &&
                    (_tool == EditorTool.drawOuter ||
                        _tool == EditorTool.drawHole)) {
                  _finishDrawing();
                  return;
                }
                if (_editorMode && _tool == EditorTool.browse) {
                  final hit = _hitTestPaddock(latlng);
                  if (hit != null) {
                    if (_editorSelecting) {
                      _editorToggleSelect(hit);
                    } else {
                      _editorBeginSelect(hit);
                    }
                  }
                  return;
                }
                if (!_navMode && !_showingHistory) {
                  final hit = _hitTestPaddock(latlng);
                  if (hit != null) {
                    if (!_workListPicking) {
                      setState(() {
                        _workListPicking = true;
                        _suppressAutoPaddockSelect = true;
                      });
                    }
                    _toggleWorkListPaddockAt(hit);
                  }
                }
              },
              onMapReady: () {
                setState(() {
                  _mapReady = true;
                  _maybeAutoSelectPaddockFromGps();
                });
                _rebuildPaddockLayers();
                _runAfterMapFrame(() {
                  if (_followGps && _dispPos != null) {
                    final hdg = _rotationMode == RotationMode.travelUp
                        ? _tractorHeadingDeg()
                        : null;
                    _swoopCamera(
                      center: _dispPos,
                      rotationDeg: hdg != null
                          ? -hdg
                          : (_rotationMode == RotationMode.northUp ? 0 : null),
                    );
                  } else {
                    _applyMapRotation(0);
                  }
                });
              },
              onPositionChanged: _onMapPositionChanged,
              onMapEvent: _onMapEvent,
            ),
            children: [
              _satellite
                  ? TileLayer(
                urlTemplate: 'https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                userAgentPackageName: 'pasturepath',
                maxNativeZoom: 19,
                tileProvider: _mapTileProvider,
              )
                  : TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'pasturepath',
                maxNativeZoom: 19,
                tileProvider: _mapTileProvider,
              ),

              // Draw paddocks first
              ValueListenableBuilder<List<Polygon>>(
                valueListenable: _paddockPolysNotifier,
                builder: (context, pdkPolys, _) {
                  if (pdkPolys.isEmpty) return const SizedBox.shrink();
                  return PolygonLayer(polygons: pdkPolys);
                },
              ),

              // Swath ABOVE paddocks so it's visible
              if (!_showingHistory)
                ValueListenableBuilder<List<Polygon>>(
                  valueListenable: _swathCommittedNotifier,
                  builder: (context, polys, _) {
                    if (polys.isEmpty) return const SizedBox.shrink();
                    return PolygonLayer(polygons: polys);
                  },
                ),
              if (!_showingHistory)
                ValueListenableBuilder<Polygon?>(
                  valueListenable: _swathLiveNotifier,
                  builder: (context, live, _) {
                    if (live == null) return const SizedBox.shrink();
                    return PolygonLayer(polygons: [live]);
                  },
                ),
              if (!_showingHistory)
                ValueListenableBuilder<Polyline?>(
                  valueListenable: _navPathCommittedNotifier,
                  builder: (context, line, _) {
                    if (line == null) return const SizedBox.shrink();
                    return PolylineLayer(polylines: [line]);
                  },
                ),
              if (!_showingHistory)
                ValueListenableBuilder<Polyline?>(
                  valueListenable: _navPathTailNotifier,
                  builder: (context, line, _) {
                    if (line == null) return const SizedBox.shrink();
                    return PolylineLayer(polylines: [line]);
                  },
                ),

              // Temporary drawing preview (outer)
              if (_editorMode &&
                  _tool == EditorTool.drawOuter &&
                  _tempOuter.length >= 2)
                PolygonLayer(polygons: [
                  Polygon(
                    points: _tempOuter,
                    color: Theme.of(context).colorScheme.secondary.withOpacity(0.10),
                    borderColor: Theme.of(context).colorScheme.secondary,
                    borderStrokeWidth: 1.2,
                  )
                ]),

              if (_editorMode &&
                  _tool == EditorTool.drawOuter &&
                  _tempOuter.isNotEmpty)
                MarkerLayer(
                  markers: [
                    for (var i = 0; i < _tempOuter.length; i++)
                      Marker(
                        point: _tempOuter[i],
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Theme.of(context).colorScheme.secondary,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),

              // Temporary hole preview
              if (_editorMode &&
                  _tool == EditorTool.drawHole &&
                  _tempHole.length >= 2)
                PolygonLayer(polygons: [
                  Polygon(
                    points: _tempHole,
                    color: Colors.red.withOpacity(0.08),
                    borderColor: Colors.redAccent,
                    borderStrokeWidth: 1.2,
                  )
                ]),

              if (_editorMode &&
                  _tool == EditorTool.drawHole &&
                  _tempHole.isNotEmpty)
                MarkerLayer(
                  markers: [
                    for (var i = 0; i < _tempHole.length; i++)
                      Marker(
                        point: _tempHole[i],
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.redAccent,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),

              if (_editorMode &&
                  _tool == EditorTool.edit &&
                  _editingIdx != null)
                _buildVertexMarkers(_paddocks[_editingIdx!]),

              // Labels above swath
              ValueListenableBuilder<List<Marker>>(
                valueListenable: _paddockLabelsNotifier,
                builder: (context, pdkLabels, _) {
                  if (pdkLabels.isEmpty) return const SizedBox.shrink();
                  return MarkerLayer(markers: pdkLabels, rotate: true);
                },
              ),

              ValueListenableBuilder<List<Polyline>>(
                valueListenable: _navLinesNotifier,
                builder: (context, navLines, _) {
                  if (navLines.isEmpty) return const SizedBox.shrink();
                  return PolylineLayer(polylines: navLines);
                },
              ),
              abPreviewLayer,
              if (_navMode)
                ValueListenableBuilder<Polyline?>(
                  valueListenable: _lookAheadNotifier,
                  builder: (context, line, _) {
                    if (line == null) return const SizedBox.shrink();
                    return PolylineLayer(polylines: [line]);
                  },
                ),
              if (_historySwathPolys.isNotEmpty) PolygonLayer(polygons: _historySwathPolys),
              if (_historyPathPolylines.isNotEmpty) PolylineLayer(polylines: _historyPathPolylines),

              if (navAbMarkers.isNotEmpty) MarkerLayer(markers: navAbMarkers),
              if (!_showingHistory)
                ValueListenableBuilder<List<Polyline>>(
                  valueListenable: _implementPolysNotifier,
                  builder: (context, polys, _) {
                    if (polys.isEmpty) return const SizedBox.shrink();
                    return PolylineLayer(polylines: polys);
                  },
                ),
              gpsMarkerLayer,
            ],
          ),

          // Paddock editor: crosshair + chrome
          if (_editorMode) ...[
            const IgnorePointer(
              child: Center(
                child: _EditorCrosshair(),
              ),
            ),
            Positioned(
              top: safe.top + _fabEdge,
              left: _fabEdge,
              right: _fabEdge + _fabSecondaryDiameter + _fabGap,
              child: _editorTitleChip(),
            ),
            if (_tool == EditorTool.browse && !_editorSelecting)
              Positioned(
                right: _fabEdge,
                bottom: _fabEdge + safe.bottom,
                child: _fatRoundActionButton(
                  icon: Icons.add,
                  heroTag: 'editorAddPaddock',
                  onPressed: _startNewPaddock,
                ),
              ),
            if (_tool == EditorTool.browse && !_editorSelecting)
              Positioned(
                left: _fabEdge,
                bottom: _fabEdge + safe.bottom,
                child: _fatRoundActionButton(
                  icon: Icons.check,
                  diameter: _fabSecondaryDiameter,
                  heroTag: 'editorDoneBrowse',
                  onPressed: _editorDone,
                ),
              ),
            if (_tool == EditorTool.browse && _editorSelecting)
              Positioned(
                left: _fabEdge,
                right: _fabEdge,
                bottom: _fabEdge + safe.bottom,
                child: _editorSelectBar(),
              ),
            if (_tool == EditorTool.drawOuter ||
                _tool == EditorTool.drawHole ||
                _tool == EditorTool.edit)
              Positioned(
                left: _fabEdge,
                right: _fabEdge,
                bottom: _fabEdge + safe.bottom,
                child: _editorActionBar(),
              ),
          ],

          // Nav dashboard + optional guidance error HUD (bar goes edge-to-edge under status bar)
          if (_navMode)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<int>(
                    valueListenable: _navHudTickNotifier,
                    builder: (context, _, __) => _navDashboard(),
                  ),
                  if (_pointA != null && _pointB != null)
                    ValueListenableBuilder<double>(
                      valueListenable: _signedErrorNotifier,
                      builder: (context, signedErrorM, _) => Center(
                        child: _ErrorChevronHud(
                          signedErrorM: signedErrorM,
                          chevronsPerSide: _chevrons,
                          controller: _chevCtrl,
                          rowWidthMeters: _toMeters(_width <= 0 ? 3.0 : _width),
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // Top chrome — floating circles (no AppBar strip over the map)
          if (!_navMode) ...[
            if (_showingHistory)
              Positioned(
                left: _fabEdge,
                top: safe.top + _fabEdge,
                child: _fatRoundActionButton(
                  icon: Icons.arrow_back,
                  diameter: _fabSecondaryDiameter,
                  onPressed: _exitHistory,
                ),
              ),
            if (!_editorMode)
              Positioned(
                right: _fabEdge,
                top: safe.top + _fabEdge,
                child: _fatRoundActionButton(
                  icon: Icons.menu,
                  diameter: _fabSecondaryDiameter,
                  onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
                ),
              ),
            if (_editorMode)
              Positioned(
                right: _fabEdge,
                top: safe.top + _fabEdge,
                child: _fatRoundActionButton(
                  icon: Icons.close,
                  diameter: _fabSecondaryDiameter,
                  heroTag: 'editorExit',
                  onPressed: _exitEditorMode,
                ),
              ),
          ],

          if ((_workList.isNotEmpty || _workListPicking) &&
              !_navMode &&
              !_editorMode &&
              !_showingHistory &&
              _completedJobSummary == null)
            Positioned(
              left: _fabEdge,
              top: _navMode ? navTopInset + 4 : safe.top + _fabEdge,
              child: _workListHudChip(),
            ),

          // Rotation toggle
          Positioned(
            right: _fabEdge,
            top: topChromeInset,
            child: _fatRoundActionButton(
              icon: _rotationIcon(),
              diameter: _fabSecondaryDiameter,
              onPressed: _cycleRotationMode,
            ),
          ),

          // Follow GPS button (shown after user pans away)
          Positioned(
            right: _fabEdge,
            top: topChromeInset + _fabSecondaryDiameter + _fabGap,
            child: FadeSwap(
              child: _showFollowGpsButton
                  ? KeyedSubtree(
                      key: const ValueKey('follow-gps'),
                      child: _fatRoundActionButton(
                        icon: Icons.my_location,
                        diameter: _fabSecondaryDiameter,
                        onPressed: _recenter,
                      ),
                    )
                  : null,
            ),
          ),

          // A/B buttons (bottom-right)
          if (_navMode && _pointA == null && _dispPos != null)
            Positioned(
              right: _fabEdge,
              bottom: _fabEdge + MediaQuery.of(context).padding.bottom,
              child: _fatRoundActionButton(
                letter: 'A',
                heroTag: 'primaryNavFab',
                onPressed: _markA,
              ),
            ),
          if (_navMode && _pointA != null && _pointB == null && _dispPos != null)
            Positioned(
              right: _fabEdge,
              bottom: _fabEdge + MediaQuery.of(context).padding.bottom,
              child: _fatRoundActionButton(
                letter: 'B',
                onPressed: _markB,
              ),
            ),

          // Finish job
          if (_navMode)
            Positioned(
              left: _fabEdge,
              bottom: _fabEdge + MediaQuery.of(context).padding.bottom,
              child: _fatRoundActionButton(
                icon: Icons.flag,
                onPressed: _finishJob,
              ),
            ),

          // Pre-nav: left info rail + Start
          if (!_navMode &&
              !_editorMode &&
              !_showingHistory &&
              _selectedIdx.isNotEmpty &&
              _completedJobSummary == null &&
              !_workListPicking) ...[
            Positioned(
              left: _fabEdge,
              bottom: _fabEdge + MediaQuery.of(context).padding.bottom,
              child: _jobSideRail(
                paddockLabel: _selectedIdx.length == 1
                    ? selectedNames.first
                    : '${_selectedIdx.length} paddocks',
                toolLabel: _toolQuickReferenceText(),
                areaLabel: _areaText(totalHa),
                historyPaddockName: singleSelectedName,
              ),
            ),
            Positioned(
              right: _fabEdge,
              bottom: _fabEdge + MediaQuery.of(context).padding.bottom,
              child: _fatRoundActionButton(
                icon: Icons.play_arrow_rounded,
                heroTag: 'primaryNavFab',
                onPressed: _startNavigation,
              ),
            ),
          ],

          if (_workListPicking &&
              !_navMode &&
              !_editorMode &&
              !_showingHistory)
            Positioned(
              left: _fabEdge,
              right: _fabEdge,
              bottom: _fabEdge + MediaQuery.of(context).padding.bottom,
              child: _workListPickingBar(),
            ),

          // Completed job summary (top — keeps bottom controls clear)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FadeSwap(
              child: (_completedJobSummary != null &&
                      !_navMode &&
                      !_editorMode &&
                      !_showingHistory)
                  ? KeyedSubtree(
                      key: ValueKey('job-summary-${_completedJobSummary!.id}'),
                      child: _completedJobSummaryPanel(),
                    )
                  : null,
            ),
          ),

          // Historic job data panel
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FadeSwap(
              child: (_showingHistory && _activeHistoryJobs.isNotEmpty)
                  ? KeyedSubtree(
                      key: const ValueKey('history-panel'),
                      child: _historyJobPanel(),
                    )
                  : null,
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// Fixed screen-center crosshair for paddock vertex placement.
class _EditorCrosshair extends StatelessWidget {
  const _EditorCrosshair();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 44,
      height: 44,
      child: CustomPaint(
        painter: _CrosshairPainter(color: color),
      ),
    );
  }
}

class _CrosshairPainter extends CustomPainter {
  _CrosshairPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final cx = size.width / 2;
    final cy = size.height / 2;
    const gap = 5.0;
    const arm = 18.0;
    canvas.drawLine(Offset(cx, cy - arm), Offset(cx, cy - gap), paint);
    canvas.drawLine(Offset(cx, cy + gap), Offset(cx, cy + arm), paint);
    canvas.drawLine(Offset(cx - arm, cy), Offset(cx - gap, cy), paint);
    canvas.drawLine(Offset(cx + gap, cy), Offset(cx + arm, cy), paint);
    canvas.drawCircle(Offset(cx, cy), 3, paint);
  }

  @override
  bool shouldRepaint(covariant _CrosshairPainter oldDelegate) =>
      oldDelegate.color != color;
}

// ---------- Historic job bottom panel ----------
class _HistoryJobPanel extends StatefulWidget {
  final List<SavedJob> jobs;
  final List<Paddock> paddocks;
  final MapController mapController;
  final bool mapReady;
  final String Function(double ha) areaText;
  final String Function(SavedJob job) jobSwathWidthText;
  final double Function(SavedJob job) jobAreaAppliedHa;
  final double Function(SavedJob job) jobCoveragePercent;
  final double Function(SavedJob job) jobSwathWidthM;
  final String Function(DateTime day) formatDayHeader;
  final String Function(DateTime t) formatTime;
  final Map<String, JobProductStats> productStatsByJobId;

  const _HistoryJobPanel({
    required this.jobs,
    required this.paddocks,
    required this.mapController,
    required this.mapReady,
    required this.areaText,
    required this.jobSwathWidthText,
    required this.jobAreaAppliedHa,
    required this.jobCoveragePercent,
    required this.jobSwathWidthM,
    required this.formatDayHeader,
    required this.formatTime,
    required this.productStatsByJobId,
  });

  @override
  State<_HistoryJobPanel> createState() => _HistoryJobPanelState();
}

class _HistoryJobPanelState extends State<_HistoryJobPanel> with TickerProviderStateMixin {
  static const _panelPadding = EdgeInsets.fromLTRB(24, 24, 24, 280);

  late TabController _tabCtrl;
  AnimationController? _mapPanCtrl;
  int _lastPannedIndex = -1;

  bool get _hasSummary => widget.jobs.length > 1;
  int get _tabCount => widget.jobs.length + (_hasSummary ? 1 : 0);

  int? _jobIndexForTab(int tabIndex) {
    if (_hasSummary) {
      if (tabIndex <= 0) return null;
      return tabIndex - 1;
    }
    return tabIndex;
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _tabCount, vsync: this);
    _tabCtrl.addListener(_onTabIndexChanged);
  }

  @override
  void didUpdateWidget(_HistoryJobPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldMulti = oldWidget.jobs.length > 1;
    final newCount = _tabCount;
    final oldCount = oldWidget.jobs.length + (oldMulti ? 1 : 0);
    if (oldCount != newCount) {
      _lastPannedIndex = -1;
      _tabCtrl.removeListener(_onTabIndexChanged);
      _tabCtrl.dispose();
      _tabCtrl = TabController(length: newCount, vsync: this);
      _tabCtrl.addListener(_onTabIndexChanged);
    }
  }

  @override
  void dispose() {
    _tabCtrl.removeListener(_onTabIndexChanged);
    _tabCtrl.dispose();
    _mapPanCtrl?.dispose();
    super.dispose();
  }

  String _paddockTabLabel(SavedJob job) {
    if (job.paddockNames.isEmpty) return '—';
    return job.paddockNames.join(', ');
  }

  LatLngBounds? _boundsForJob(SavedJob job) {
    final paddockPts = <LatLng>[];
    for (final name in job.paddockNames) {
      for (final pd in widget.paddocks) {
        if (pd.name == name) paddockPts.addAll(pd.outer);
      }
    }
    if (paddockPts.length >= 2) return LatLngBounds.fromPoints(paddockPts);
    if (job.path.length >= 2) return LatLngBounds.fromPoints(job.path);
    return null;
  }

  LatLngBounds? _boundsForAllJobs() {
    final pts = <LatLng>[];
    for (final job in widget.jobs) {
      for (final name in job.paddockNames) {
        for (final pd in widget.paddocks) {
          if (pd.name == name) pts.addAll(pd.outer);
        }
      }
      if (job.path.length >= 2) pts.addAll(job.path);
    }
    if (pts.length < 2) return null;
    return LatLngBounds.fromPoints(pts);
  }

  void _onTabIndexChanged() {
    if (_tabCtrl.indexIsChanging) return;
    final idx = _tabCtrl.index;
    if (idx == _lastPannedIndex) return;
    _lastPannedIndex = idx;
    final jobIdx = _jobIndexForTab(idx);
    if (jobIdx == null) {
      _panToBounds(_boundsForAllJobs());
    } else if (jobIdx >= 0 && jobIdx < widget.jobs.length) {
      _panToJob(widget.jobs[jobIdx]);
    }
  }

  void _panToJob(SavedJob job, {bool animate = true}) {
    _panToBounds(_boundsForJob(job), animate: animate);
  }

  void _panToBounds(LatLngBounds? bounds, {bool animate = true}) {
    if (!widget.mapReady || bounds == null) return;

    final target = CameraFit.bounds(bounds: bounds, padding: _panelPadding)
        .fit(widget.mapController.camera);
    final endCenter = target.center;
    final endZoom = target.zoom;

    _mapPanCtrl?.stop();
    _mapPanCtrl?.dispose();

    if (!animate) {
      widget.mapController.move(endCenter, endZoom);
      return;
    }

    final startCenter = widget.mapController.camera.center;
    final startZoom = widget.mapController.camera.zoom;

    _mapPanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    final curved = CurvedAnimation(
      parent: _mapPanCtrl!,
      curve: Curves.easeInOutCubic,
    );
    curved.addListener(() {
      final t = curved.value;
      widget.mapController.move(
        LatLng(
          startCenter.latitude + (endCenter.latitude - startCenter.latitude) * t,
          startCenter.longitude + (endCenter.longitude - startCenter.longitude) * t,
        ),
        startZoom + (endZoom - startZoom) * t,
      );
    });
    _mapPanCtrl!.forward();
  }

  Widget _historyStat(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryTab(ColorScheme scheme) {
    final jobs = widget.jobs;
    final totalHa = jobs.fold(0.0, (s, j) => s + j.totalHa);
    final appliedHa =
        jobs.fold(0.0, (s, j) => s + widget.jobAreaAppliedHa(j));
    final coverage = totalHa > 0
        ? (appliedHa / totalHa * 100).clamp(0, double.infinity)
        : 0.0;

    final paddockNames = <String>{};
    for (final j in jobs) {
      paddockNames.addAll(j.paddockNames);
    }

    // Product totals keyed by display unit.
    final rateSumByUnit = <String, double>{};
    final rateCountByUnit = <String, int>{};
    final amountByUnit = <String, double>{};
    String? productName;
    for (final j in jobs) {
      final p = widget.productStatsByJobId[j.id];
      if (p == null) continue;
      productName ??= p.productName;
      final u = p.recordUnitLabel;
      rateSumByUnit[u] = (rateSumByUnit[u] ?? 0) + p.ratePerHa;
      rateCountByUnit[u] = (rateCountByUnit[u] ?? 0) + 1;
      amountByUnit[u] = (amountByUnit[u] ?? 0) + p.amount;
    }

    final started = jobs.map((j) => j.startedAt).reduce(
          (a, b) => a.isBefore(b) ? a : b,
        );
    final ended = jobs.map((j) => j.endedAt).reduce(
          (a, b) => a.isAfter(b) ? a : b,
        );
    final avgSpeed = jobs.fold(0.0, (s, j) => s + j.avgSpeedKph) / jobs.length;

    final productLines = <String>[];
    for (final u in amountByUnit.keys) {
      final count = rateCountByUnit[u] ?? 0;
      final avgRate = count > 0 ? (rateSumByUnit[u]! / count) : 0.0;
      final name = (productName != null && productName.trim().isNotEmpty)
          ? '${productName.trim()} '
          : '';
      productLines.add(
        '$name${avgRate.toStringAsFixed(0)} $u/ha · '
        '${amountByUnit[u]!.toStringAsFixed(0)} $u',
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${jobs.length} jobs'
              '${paddockNames.isEmpty ? '' : ' · ${paddockNames.join(', ')}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _historyStat('Area', widget.areaText(totalHa)),
                _historyStat('Applied', widget.areaText(appliedHa)),
                _historyStat('Coverage', '${coverage.toStringAsFixed(0)}%'),
                _historyStat('Avg speed', '${avgSpeed.toStringAsFixed(1)} km/h'),
                for (final line in productLines)
                  _historyStat('Product', line),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.formatDayHeader(DateTime(started.year, started.month, started.day))}  '
              '${widget.formatTime(started)} – ${widget.formatTime(ended)}',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJobTab(SavedJob j, ColorScheme scheme) {
    final product = widget.productStatsByJobId[j.id];
    final applied = widget.jobAreaAppliedHa(j);
    final duration = j.endedAt.difference(j.startedAt);
    final durMin = duration.inMinutes;
    final durLabel = durMin >= 60
        ? '${durMin ~/ 60}h ${durMin % 60}m'
        : '${durMin}m';
    final thisJobTarget = product == null
        ? null
        : '${product.amount.toStringAsFixed(0)} ${product.recordUnitLabel}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _paddockTabLabel(j),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              j.id,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                _historyStat('Area', widget.areaText(j.totalHa)),
                _historyStat('Applied', widget.areaText(applied)),
                _historyStat(
                  'Coverage',
                  '${widget.jobCoveragePercent(j).toStringAsFixed(0)}%',
                ),
                _historyStat('Swath', widget.jobSwathWidthText(j)),
                _historyStat('Avg speed', '${j.avgSpeedKph.toStringAsFixed(1)} km/h'),
                _historyStat('Duration', durLabel),
                if (product != null) ...[
                  _historyStat(
                    product.productName?.trim().isNotEmpty == true
                        ? product.productName!.trim()
                        : 'Product',
                    product.historyLabel,
                  ),
                  if (thisJobTarget != null)
                    _historyStat('Amount', thisJobTarget),
                  if (product.carrierRatePerHa != null)
                    _historyStat(
                      'Spray rate',
                      '${product.carrierRatePerHa!.toStringAsFixed(0)} L/ha',
                    ),
                  if (product.carrierAmount != null)
                    _historyStat(
                      'Spray amt',
                      '${product.carrierAmount!.toStringAsFixed(0)} L',
                    ),
                ],
                if (j.weather != null && j.weather!.shortLabel != '—')
                  _historyStat('Weather', j.weather!.shortLabel),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.formatDayHeader(DateTime(j.startedAt.year, j.startedAt.month, j.startedAt.day))}  '
              '${widget.formatTime(j.startedAt)} – ${widget.formatTime(j.endedAt)}',
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final jobs = widget.jobs;
    final scheme = Theme.of(context).colorScheme;

    final tabs = <Tab>[
      if (_hasSummary) const Tab(text: 'Summary'),
      ...jobs.map((j) => Tab(text: _paddockTabLabel(j))),
    ];
    final views = <Widget>[
      if (_hasSummary) _buildSummaryTab(scheme),
      ...jobs.map((j) => _buildJobTab(j, scheme)),
    ];

    return Material(
      elevation: 8,
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        maintainBottomViewPadding: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TabBar(
              controller: _tabCtrl,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              tabs: tabs,
            ),
            SizedBox(
              // Scrollable detail room above system nav (full fallback stats).
              height: 220,
              child: TabBarView(
                controller: _tabCtrl,
                children: views,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Thick Chevron Painter + HUD ----------
class _ErrorChevronHud extends StatelessWidget {
  final double signedErrorM; // +ve => steer right, -ve => steer left
  final int chevronsPerSide;
  final AnimationController controller;
  final double rowWidthMeters;
  final bool pipMode;

  const _ErrorChevronHud({
    required this.signedErrorM,
    required this.chevronsPerSide,
    required this.controller,
    required this.rowWidthMeters,
    this.pipMode = false,
  });

  Color _gradColorFromCenter(int idxFromCenter, int total) {
    // 0 (inner) -> green, total-1 (outer) -> red
    final t = (idxFromCenter / (total - 1)).clamp(0.0, 1.0);
    final hue = 0.33 - 0.33 * t; // 0.33=green .. 0.0=red
    return HSVColor.fromAHSV(1.0, hue * 360.0, 0.95, 0.95).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final err = signedErrorM;
    final absErr = err.abs();
    final halfSpan = (rowWidthMeters * 0.5).clamp(0.1, 999.0);
    final severity = (absErr / halfSpan).clamp(0.0, 1.0);
    final activeCount = (severity * chevronsPerSide).ceil();

    final needRight = err > 0;
    final needLeft  = err < 0;

    Widget side(bool isRightSide) {
      // Visual order: LEFT side draws OUTER->INNER; RIGHT side draws INNER->OUTER.
      // Delay order (for animation): always INNER(0) -> OUTER(total-1) so it
      // propagates AWAY from center on the correcting side.
      return AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          final baseAlpha = 0.35; // dark grey base

          return LayoutBuilder(
            builder: (ctx, constraints) {
              final reservedForCenter = 100.0; // room for the error box and padding
              final availPerSide = ((constraints.maxWidth - reservedForCenter) / 2)
                  .clamp(76.0, 320.0);

              const chevronGap = 3.0;
              final tileW = ((availPerSide - (chevronsPerSide - 1) * chevronGap) / chevronsPerSide)
                  .clamp(18.0, 26.0);
              final tileH = (tileW * 0.95).clamp(18.0, 30.0);
              final baseThickness = (tileW * 0.28).clamp(5.4, 7.0);
              final overlayThickness = baseThickness + 0.8;

              final tiles = <Widget>[];
              for (int visualIdx = 0; visualIdx < chevronsPerSide; visualIdx++) {
                // spatialIdxFromCenter: 0=INNER, total-1=OUTER (for delay + color)
                final spatialIdxFromCenter = isRightSide
                    ? visualIdx                    // right laid INNER->OUTER
                    : (chevronsPerSide - 1 - visualIdx); // left laid OUTER->INNER

                final isActive = spatialIdxFromCenter < activeCount &&
                    ((isRightSide && needRight) || (!isRightSide && needLeft));

                // Animate INNER first, then OUTER — away from center
                final delay = (spatialIdxFromCenter * 0.10);
                final phase = (controller.value + delay) % 1.0;
                final pulse = 0.5 + 0.5 * math.sin(phase * 2 * math.pi);
                final eased = Curves.easeInOut.transform(pulse);

                final overlayColor = _gradColorFromCenter(spatialIdxFromCenter, chevronsPerSide)
                    .withOpacity(isActive ? (0.18 + 0.82 * eased) : 0.0);

                tiles.add(Container(
                  margin: EdgeInsets.only(
                    right: isRightSide ? chevronGap : 0,
                    left:  isRightSide ? 0 : chevronGap,
                  ),
                  width: tileW,
                  height: tileH,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        painter: _ChevronPainter(
                          right: isRightSide,
                          color: Colors.grey.shade800.withOpacity(baseAlpha),
                          thickness: baseThickness,
                        ),
                      ),
                      if (isActive)
                        CustomPaint(
                          painter: _ChevronPainter(
                            right: isRightSide,
                            color: overlayColor,
                            thickness: overlayThickness,
                          ),
                        ),
                    ],
                  ),
                ));
              }

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: tiles,
              );
            },
          );
        },
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.32),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          side(false), // LEFT side
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.66),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${absErr.toStringAsFixed(1)} m',
              style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          side(true),  // RIGHT side
        ],
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  final bool right;
  final Color color;
  final double thickness;
  _ChevronPainter({required this.right, required this.color, required this.thickness});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    // Draw a ">" or "<" using two strokes
    final w = size.width, h = size.height;
    final p1 = Offset(right ? 0 : w, 0);
    final p2 = Offset(w * 0.6, h * 0.5);
    final p3 = Offset(right ? 0 : w, h);

    canvas.drawLine(p1, p2, paint);
    canvas.drawLine(p2, p3, paint);
  }

  @override
  bool shouldRepaint(covariant _ChevronPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.thickness != thickness || oldDelegate.right != right;
  }
}

/// Progress dialog that owns the tile prefetch and always pops itself.
class _CacheMapDialog extends StatefulWidget {
  const _CacheMapDialog({
    required this.bounds,
    required this.urlTemplate,
  });

  final LatLngBounds bounds;
  final String urlTemplate;

  @override
  State<_CacheMapDialog> createState() => _CacheMapDialogState();
}

class _CacheMapDialogState extends State<_CacheMapDialog> {
  int _done = 0;
  int _total = 0;
  bool _cancelled = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    var done = 0;
    try {
      done = await MapTileCache.prefetchBounds(
        bounds: widget.bounds,
        urlTemplate: widget.urlTemplate,
        minZoom: 13,
        maxZoom: 16,
        maxTiles: 2500,
        isCancelled: () => _cancelled,
        onProgress: (d, t) {
          if (!mounted || _cancelled) return;
          setState(() {
            _done = d;
            _total = t;
          });
        },
      );
    } catch (_) {
      // Still dismiss so the UI never sticks.
    }
    if (!mounted || _finished) return;
    _finished = true;
    Navigator.of(context).pop((done: done, cancelled: _cancelled));
  }

  void _cancel() {
    if (_finished) return;
    setState(() => _cancelled = true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Caching map'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              value: _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null,
            ),
            const SizedBox(height: 12),
            Text(
              _cancelled
                  ? 'Stopping…'
                  : (_total > 0 ? '$_done / $_total tiles' : 'Preparing…'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _cancelled ? null : _cancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _AppVersionTile extends StatefulWidget {
  @override
  State<_AppVersionTile> createState() => _AppVersionTileState();
}

class _AppVersionTileState extends State<_AppVersionTile> {
  String? _latestVersion;
  bool _loading = true;
  String? _error;
  static const _repoUrl = 'https://github.com/Cowman57/PasturePath';
  static const _releasesUrl = '$_repoUrl/releases';
  static const _apiUrl = '$_repoUrl/releases/latest';

  @override
  void initState() {
    super.initState();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    try {
      final uri = Uri.parse(_apiUrl);
      final resp = await http.get(uri, headers: {'Accept': 'application/json'});
      if (resp.statusCode != 200) {
        if (mounted) setState(() { _loading = false; _error = 'Check failed (${resp.statusCode})'; });
        return;
      }
      final data = json.decode(resp.body) as Map;
      final tag = data['tag_name'] as String?;
      if (mounted) setState(() { _latestVersion = tag; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snap) {
        final version = snap.data?.version ?? '—';
        final buildNumber = snap.data?.buildNumber ?? '—';
        final currentVersion = 'v$version+$buildNumber';
        final currentTag = 'v$version';

        String subtitle;
        Widget? trailing;
        Color? titleColor;
        IconData? icon;

        if (_loading) {
          subtitle = 'Checking for updates…';
          icon = Icons.refresh;
        } else if (_error != null) {
          subtitle = 'Failed to check: $_error';
          icon = Icons.error_outline;
          trailing = IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _checkUpdate,
            tooltip: 'Retry',
          );
        } else if (_latestVersion != null && _latestVersion != currentTag) {
          subtitle = '$currentVersion → $_latestVersion available';
          icon = Icons.new_releases;
          titleColor = Theme.of(context).colorScheme.primary;
          trailing = ElevatedButton(
            onPressed: () => launchUrl(Uri.parse(_releasesUrl), mode: LaunchMode.externalApplication),
            child: const Text('Download Update'),
          );
        } else {
          subtitle = '$currentVersion (up to date)';
          icon = Icons.check_circle;
          trailing = IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _checkUpdate,
            tooltip: 'Check for updates',
          );
        }

        return GestureDetector(
          onTap: _loading ? null : _checkUpdate,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.1),
            ),
            child: Row(
              children: [
                if (icon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Icon(icon, color: titleColor, size: 28),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PasturePath',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade700,
                        ),
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
                if (trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: trailing,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
