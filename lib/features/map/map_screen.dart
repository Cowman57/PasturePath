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
import 'package:flutter_map_dragmarker/flutter_map_dragmarker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app_theme.dart';
import '../../models/paddock.dart';
import '../../models/job.dart';
import '../../models/gps_fix.dart';
import '../../services/backup_store.dart';
import '../../services/job_store.dart';
import '../../services/geometry.dart';
import '../../services/geojson_parser.dart';
import '../../services/gps_display_smoother.dart';
import '../../services/gps/gps_input_controller.dart';
import '../../services/gps/gps_source.dart';
import '../../services/implement_kinematics.dart';
import '../../models/tool_setup_dimensions.dart';
import '../../services/tool_preset_store.dart';
import '../../widgets/navigation_arrow_icon.dart';
import 'tool_setup_tab.dart';


enum EditorTool { none, drawOuter, drawHole, edit }



enum RotationMode { northUp, travelUp, free }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  bool _editorEnabled = false;
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

  // selection
  final Set<int> _selectedIdx = <int>{};
  bool _suppressAutoPaddockSelect = false;
  int? _lastGpsInsidePaddockIdx;
  int _lastAutoSelectMs = 0;
  static const int _autoSelectIntervalMs = 500;

  // nav
  bool _navMode = false;
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
  LatLng? _lastCameraTarget;
  double? _lastCameraRotationDeg;

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
  double _appliedDistanceM = 0.0;
  double _currentSpeedKph = 0.0;
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
  static const double _minGpsRecordM = 0.45;
  static const double _maxGpsJumpM = 35.0;
  static const double _minMovingSpeedMps = 0.4;
  /// Stronger simplify on save keeps job files smaller for history / map show.
  static const double _jobSaveSimplifyMinDistM = 1.25;
  /// Display rebuild: keep continuous rings (no chunk seams). Throttle for lag.
  static const double _swathDisplaySimplifyMinDistM = 0.55;
  static const int _swathCommitIntervalMs = 400;
  static const double _swathCommitMinAdvanceM = 2.0;
  // ====== Paddock Editor ======
  EditorTool _tool = EditorTool.none;

  // drawing a new paddock (outer ring)
  final List<LatLng> _tempOuter = [];
  // drawing a new hole for an existing paddock
  final List<LatLng> _tempHole = [];

  // current paddock selected for editing / hole insertion
  int? _editingIdx;

  // snap & hit settings
  static const double _snapMeters = 8;   // threshold to snap-close polygon
  static const double _hitMeters  = 150; // centroid pick radius

  void _undoLastPoint() {
    if (_tool == EditorTool.drawOuter && _tempOuter.isNotEmpty) {
      setState(() => _tempOuter.removeLast());
    } else if (_tool == EditorTool.drawHole && _tempHole.isNotEmpty) {
      setState(() => _tempHole.removeLast());
    }
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
    // Smooth pulsing animation for chevrons
    _chevCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();

    _drawerTabCtrl = TabController(length: 3, vsync: this);

    _gpsSmoothTicker = createTicker(_onGpsSmoothTick);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadPrefs();
      _toolPresets = await ToolPresetStore.list();
      if (_selectedToolPresetName != null) {
        final ok = _toolPresets.any(
          (e) => e.name.toLowerCase() == _selectedToolPresetName!.toLowerCase(),
        );
        if (!ok) _selectedToolPresetName = null;
      }
      if (mounted) setState(() {});
      await _loadPersistedFarmJsonIfAny();
      await _ensureLocationFlow();
    });
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
    _chevCtrl.dispose();
    _drawerTabCtrl.dispose();
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
    final ok = await showDialog<bool>(
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
    _resetToMapDefaults();
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
    await _gpsInput.start();
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
    switch (_rotationMode) {
      case RotationMode.northUp:
        final rot = _mapController.camera.rotation;
        if (rot.abs() > 0.01) {
          final last = _lastCameraRotationDeg;
          if (last == null || last.abs() > 0.01) {
            _applyMapRotation(0);
            _lastCameraRotationDeg = 0;
          }
        }
        break;
      case RotationMode.travelUp:
        final hdg = _tractorHeadingDeg();
        if (hdg != null) {
          final target = -hdg;
          final last = _lastCameraRotationDeg;
          if (last == null ||
              (target - last).abs() >= _cameraRotateThresholdDeg) {
            _applyMapRotation(target);
            _lastCameraRotationDeg = target;
          }
        }
        break;
      case RotationMode.free:
        break;
    }
    if (_followGps && !_showingHistory) {
      final last = _lastCameraTarget;
      // In nav, keep the camera glued to GPS; looser threshold only when browsing.
      final threshold = _navMode ? 0.15 : _cameraMoveThresholdM;
      final needMove = last == null ||
          const Distance().as(LengthUnit.Meter, last, _dispPos!) >= threshold;
      if (needMove) {
        _mapController.move(_dispPos!, _mapController.camera.zoom);
        _lastCameraTarget = _dispPos;
      }
    }
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

  double _navSelectedTotalHa() =>
      _selectedIdx.fold(0.0, (s, i) => s + _paddocks[i].areaHa);

  double _navLiveAppliedAreaHa() =>
      _appliedDistanceM * _currentSwathWidthM() / 10000.0;

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
            stat('Covered', _areaText(_navLiveAppliedAreaHa())),
            stat('Coverage', '${_navLiveCoveragePercent().toStringAsFixed(0)}%'),
            stat('Avg speed', '${_navLiveAvgSpeedKph().toStringAsFixed(1)} km/h'),
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

  /// Drop micro zig-zag boom hops that inflate applied metres (mirrors simplify).
  bool _isSharpZigZagBoomStep(double boomSegM) {
    if (_jobPath.length < 3 || boomSegM >= 3.0) return false;
    final a = _jobPath[_jobPath.length - 3];
    final b = _jobPath[_jobPath.length - 2];
    final c = _jobPath.last;
    final bearingIn = const Distance().bearing(a, b);
    final bearingOut = const Distance().bearing(b, c);
    var turn = bearingOut - bearingIn;
    while (turn > 180) {
      turn -= 360;
    }
    while (turn < -180) {
      turn += 360;
    }
    return turn.abs() > 28;
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
    final dt =
        p.timestamp.difference(_lastSpeedFixTime!).inMilliseconds / 1000.0;
    if (dt > 0 && dt < 20) {
      _speedDistanceM += p.speedMps! * dt;
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

  void _applyMapRotation(double degrees) {
    if (!_mapReady) {
      _mapController.rotate(degrees);
      return;
    }
    var target = degrees;
    final current = _mapController.camera.rotation;
    // Pick equivalent angle nearest to current to avoid 360° spins in travel-up.
    var best = target;
    var bestAbs = (target - current).abs();
    for (final candidate in [target - 360, target + 360]) {
      final d = (candidate - current).abs();
      if (d < bestAbs) {
        bestAbs = d;
        best = candidate;
      }
    }
    _mapController.rotate(best);
  }

  void _resetToMapDefaults({bool moveToGps = true}) {
    setState(() {
      _rotationMode = RotationMode.northUp;
      _followGps = true;
    });
    if (_mapReady) {
      _applyMapRotation(0);
      if (moveToGps && _dispPos != null) {
        _mapController.move(_dispPos!, _mapController.camera.zoom);
      }
    }
  }

  void _onMapPositionChanged(MapPosition position, bool hasGesture) {
    _maybeRefreshPaddockLayersForZoom();
    if (!hasGesture || _showingHistory) return;
    // Stop follow immediately so controller moves don't fight the pan gesture.
    if (_followGps) {
      setState(() => _followGps = false);
    }
  }

  void _onMapEvent(MapEvent event) {
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
      _mapController.move(_dispPos!, _mapController.camera.zoom);
      _lastCameraTarget = _dispPos;
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
    if (_selectedIdx.isEmpty) return true;
    for (final i in _selectedIdx) {
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
    final zoom = _mapReady ? _mapController.camera.zoom : 0.0;
    final showLabels = zoom >= 15.0;
    _paddockLabelsZoomVisible = showLabels;

    for (int i = 0; i < _paddocks.length; i++) {
      final pd = _paddocks[i];
      final isSel = _selectedIdx.contains(i);
      polys.add(
        Polygon(
          points: pd.outer,
          holePointsList: pd.holes,
          color: _overlayColor.withOpacity(
            (_overlayOpacity + (isSel ? 0.08 : 0.0)).clamp(0.0, 1.0),
          ),
          borderColor: isSel ? Colors.yellow.shade700 : _overlayColor,
          borderStrokeWidth: isSel ? 3.5 : 2.0,
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

    if (_navMode) {
      await _onBackDuringNavigation();
      return true;
    }

    if (_editorEnabled && _tool != EditorTool.none) {
      if ((_tool == EditorTool.drawOuter && _tempOuter.isNotEmpty) ||
          (_tool == EditorTool.drawHole && _tempHole.isNotEmpty)) {
        _undoLastPoint();
        return true;
      }
      setState(() {
        _tool = EditorTool.none;
        _tempOuter.clear();
        _tempHole.clear();
        _editingIdx = null;
      });
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
    final choice = await showDialog<String>(
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
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
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
        _lastTravelBearingDeg = const Distance().bearing(prev, gps);
        _rebuildJobPathFromGps();
        _syncNavPathCommitted();
        _syncSwathDisplay(forceCommit: true);
        return;
      }
    }

    final prevBoom = _jobPath.isNotEmpty ? _jobPath.last : null;

    _gpsRecordPath.add(gps);
    if (prev != null) {
      _lastTravelBearingDeg = const Distance().bearing(prev, gps);
    }
    _rebuildJobPathFromGps();

    // Applied metres from boom-centre advance (less GPS zig-zag inflation).
    // Overlaps still count because separate passes still add length.
    final speedOk = p.hasSpeed && p.speedMps! >= _minMovingSpeedMps;
    if (prev != null &&
        prevBoom != null &&
        _jobPath.isNotEmpty &&
        speedOk &&
        (_selectedIdx.isEmpty ||
            (_inSelectedPaddock(prev) && _inSelectedPaddock(gps)))) {
      final boomSegM =
          const Distance().as(LengthUnit.Meter, prevBoom, _jobPath.last);
      if (boomSegM > 0 &&
          boomSegM <= _maxGpsJumpM &&
          !_isSharpZigZagBoomStep(boomSegM)) {
        _appliedDistanceM += boomSegM;
      }
    }

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
      if (_selectedIdx.isEmpty) {
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
      for (final i in _selectedIdx) {
        final pd = _paddocks[i];
        out.addAll(clipLineABToPolygonExact(aa, bb, pd.outer, pd.holes));
      }
      return out;
    }

    final polylines = <List<List<LatLng>>>[];
    final mid = LatLng((a.latitude + b.latitude) * 0.5, (a.longitude + b.longitude) * 0.5);

    double maxSpan;
    double alongExtentM;
    if (_selectedIdx.isEmpty) {
      maxSpan = _approxSpanMeters(_mapController.camera.visibleBounds);
      alongExtentM = maxSpan * 2;
    } else {
      final rings = <List<LatLng>>[];
      for (final i in _selectedIdx) {
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
    _rebuildPaddockLayers();

    if (_paddocks.isNotEmpty && _mapReady) {
      _mapController.move(_paddocks.first.labelPoint, 16);
    }
  }

  // ---------- Map taps ----------

  void _onMapTap(TapPosition _, LatLng p) {
    // Selection should always work. Editor-specific behavior only when enabled.
    int? hit = _hitTestPaddock(p);

    if (!_editorEnabled) {
      // Editor hidden → normal selection
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
      return;
    }

    // Editor is visible
    if (_tool == EditorTool.drawOuter) {
      _handleDrawOuterTap(p);
      return;
    }
    if (_tool == EditorTool.drawHole) {
      _handleDrawHoleTap(p);
      return;
    }
    if (_tool == EditorTool.edit) {
      // In edit mode, taps can switch which paddock is being edited
      if (hit != null) {
        setState(() {
          _selectedIdx
            ..clear()
            ..add(hit);
          _editingIdx = hit;
        });
        _rebuildPaddockLayers();
      }
      return;
    }

    // No tool active → treat as selection
    if (hit != null) {
      setState(() {
        _selectedIdx
          ..clear()
          ..add(hit);
        _editingIdx = hit;
      });
    } else {
      setState(() {
        _selectedIdx.clear();
        _editingIdx = null;
      });
    }
    _rebuildPaddockLayers();



  }

  Widget _toolbarBtn(String label, {required VoidCallback onTap, bool enabled = true}) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: enabled ? null : Theme.of(context).disabledColor,
        )),
      ),
    );
  }

  Widget _buildVertexEditor(Paddock p) {
    if (!_editorEnabled || _tool != EditorTool.edit || _editingIdx == null) return const SizedBox.shrink();
    final handles = <DragMarker>[];

    void addRing(List<LatLng> ring, void Function(int, LatLng) updateAt) {
      for (var i = 0; i < ring.length; i++) {
        final pt = ring[i];
        handles.add(DragMarker(
          point: pt,
          size: const Size(22, 22),
          builder: (ctx, pos, isDragging) => Container(
            width: 18, height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDragging
                  ? Theme.of(ctx).colorScheme.tertiary
                  : Theme.of(ctx).colorScheme.primary,
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
            ),
          ),
          onDragEnd: (details, newPos) {
            setState(() { updateAt(i, newPos); });
            _recalcPaddock(_editingIdx!);
            _persistFarmJson(_buildFarmGeoJsonBytes());
          },
        ));
      }
    }

    addRing(p.outer, (i, pos) => p.outer[i] = pos);
    for (var h = 0; h < p.holes.length; h++) {
      addRing(p.holes[h], (i, pos) => p.holes[h][i] = pos);
    }

    return DragMarkers(markers: handles);
  }

  int? _pickPaddockForEdit() {
    if (_selectedIdx.isNotEmpty) return _selectedIdx.last;
    double best = double.infinity;
    int? bestIdx;
    for (var i = 0; i < _paddocks.length; i++) {
      final c = _centroid(_paddocks[i].outer);
      final d = const Distance().distance(c, _dispPos ?? c);
      if (d < best && d <= _hitMeters) { best = d; bestIdx = i; }
    }
    return bestIdx;
  }

  Future<String?> _promptName(BuildContext context) async {
    final c = TextEditingController();
    return showDialog<String>(
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
    if (_showingHistory || _editorEnabled) return;
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
    if (clearMap) _clearSwathDisplay();
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

  void _handleDrawOuterTap(LatLng ll) {
    if (_tempOuter.isNotEmpty) {
      final d = const Distance().distance(_tempOuter.first, ll);
      if (d < 3.0) { // snap to first point ~3m
        _finishDrawing();
        return;
      }
    }
    setState(() => _tempOuter.add(ll));
  }

  void _handleDrawHoleTap(LatLng ll) {
    if (_tempHole.isNotEmpty) {
      final d = const Distance().distance(_tempHole.first, ll);
      if (d < 3.0) { // snap to first
        _finishDrawing();
        return;
      }
    }
    setState(() => _tempHole.add(ll));
  }

  Future<void> _finishDrawing() async {
    if (_tool == EditorTool.drawOuter) {
      if (_tempOuter.length < 3) return;
      final name = await _promptName(context);
      if (name == null || name.isEmpty) return;
      final outer = List<LatLng>.from(_tempOuter);
      final holes = <List<LatLng>>[];
      final area = _areaHa(outer, holes);
      final lp = _labelPoint(outer, holes);
      setState(() {
        _paddocks.add(Paddock(name: name, outer: outer, holes: holes, areaHa: area, labelPoint: lp));
        _tool = EditorTool.none;
        _tempOuter.clear();
        _editingIdx = _paddocks.length - 1;
        if (!_selectedIdx.contains(_editingIdx)) _selectedIdx.add(_editingIdx!);
      });
      await _persistFarmJson(_buildFarmGeoJsonBytes());
      _rebuildPaddockLayers();
      return;
    }
    if (_tool == EditorTool.drawHole && _editingIdx != null) {
      if (_tempHole.length < 3) return;
      final idx = _editingIdx!;
      setState(() {
        _paddocks[idx].holes.add(List<LatLng>.from(_tempHole));
        _recalcPaddock(idx);
        _tool = EditorTool.none;
        _tempHole.clear();
      });
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
      _appliedDistanceM = 0.0;
      _currentSpeedKph = 0.0;
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

    if (_mapReady && _dispPos != null) {
      final hdg = _tractorHeadingDeg();
      if (hdg != null) _applyMapRotation(-hdg);
      final p = _dispPos!;
      final latRad = p.latitude * math.pi / 180.0;
      final widthM = _toMeters(_width <= 0 ? 3.0 : _width);
      final acrossM = widthM * 3.0;
      final screenW = MediaQuery.of(context).size.width;
      final mpp0 = 156543.03392 * math.cos(latRad);
      final denom = (screenW * mpp0 / acrossM).clamp(1.0, 1e12);
      final z = math.log(denom) / math.ln2;
      _mapController.move(p, z.clamp(5.0, 22.0));
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
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
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
      // Prefer live boom-gated applied metres; fall back to simplified path length.
      final pathDistanceM = _appliedDistanceM > 0
          ? _appliedDistanceM
          : pathDistanceMeters(savedPath);

      final durHrs = end.difference(_jobStartTime!).inMilliseconds / 3600000.0;
      final avgKph = durHrs > 0 ? (_speedDistanceM / 1000.0) / durHrs : 0.0;

      final names = _selectedIdx.map((i) => _paddocks[i].name).toList()..sort();
      final totalHa = _selectedIdx.fold(0.0, (s, i) => s + _paddocks[i].areaHa);

      final n = await JobStore.nextSequenceForDay(end);
      final id = JobStore.dayTitle(end, n);

      final displayWidth = _currentWidthDisplay();
      final widthM = _toMeters(displayWidth);

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
      );

      await JobStore.save(job);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      setState(() {
        _navMode = false;
        _pointA = null;
        _pointB = null;
        _navLinesNotifier.value = [];
        _guidanceParallelLines.clear();
        _lookAheadNotifier.value = null;
        _completedJobSummary = job;
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
        if (_paddocks.isNotEmpty || _persistedJsonPath != null)
          ListTile(
            leading: const Icon(Icons.delete),
            title: const Text('Clear JSON'),
            onTap: () async {
              setState(() {
                _paddocks = [];
                _selectedIdx.clear();
                _navMode = false;
                _navLinesNotifier.value = [];
      _guidanceParallelLines = [];
                _pointA = null;
                _pointB = null;
                _lookAheadNotifier.value = null;
      _clearSwathDisplay();
              });
              _rebuildPaddockLayers();
              final p = await SharedPreferences.getInstance();
              await p.remove('farmJsonPath');
              _persistedJsonPath = null;
            },
          ),

        const Divider(),
        ListTile(
          leading: Icon(Icons.edit_note),
          title: Text(_editorEnabled ? 'Hide paddock editor' : 'Show paddock editor'),
          subtitle: const Text('Draw paddocks, holes, and edit vertices'),
          onTap: () {
            setState(() {
              _editorEnabled = !_editorEnabled;
              if (!_editorEnabled) {
                _tool = EditorTool.none;
                _tempOuter.clear();
                _tempHole.clear();
                _editingIdx = null;
              }
            });
            Navigator.of(context).maybePop();
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
                  final ok = await showDialog<bool>(
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
                          final ok = await showDialog<bool>(
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
                                        '${dayJobs.length} job${dayJobs.length == 1 ? '' : 's'} · ${_areaText(dayTotalHa)}',
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
                              DataColumn(label: Text('Time', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                              DataColumn(label: Text('Coverage', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12))),
                            ],
                            rows: dayJobs.map((entry) {
                              final j = entry;
                              final selected = _histSelected.contains(entry.filePath);
                              final paddock = j.paddockNames.join(', ');
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
                                  DataCell(Text(_formatTime(j.startedAt), style: const TextStyle(fontSize: 12))),
                                  DataCell(Text('${_summaryCoveragePercent(j).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 12))),
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
              const SizedBox(height: 2),
              Text(
                j.id,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSecondaryContainer.withOpacity(0.75),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  stat('Area', _areaText(j.totalHa)),
                  stat('Applied', _areaText(_jobAreaAppliedHa(j))),
                  stat('Coverage', '${_jobCoveragePercent(j).toStringAsFixed(0)}%'),
                  stat('Swath', _jobSwathWidthText(j)),
                  stat('Avg speed', '${j.avgSpeedKph.toStringAsFixed(1)} km/h'),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${_formatDayHeader(DateTime(j.startedAt.year, j.startedAt.month, j.startedAt.day))}  ${_formatTime(j.startedAt)} – ${_formatTime(j.endedAt)}',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSecondaryContainer.withOpacity(0.75),
                ),
              ),
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
    );
  }

  Future<void> _showPaddockHistory(String paddockName) async {
    final summaries = await JobStore.listJobSummaries();
    final rows = summaries
        .where((j) => j.paddockNames.contains(paddockName))
        .toList();

    if (!mounted) return;
    // ignore: use_build_context_synchronously
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        if (rows.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('No history for this paddock.'));
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final j = rows[i];
            return ListTile(
              leading: const Icon(Icons.route),
              title: Text(j.id),
              subtitle: Text('Area: ${j.totalHa.toStringAsFixed(1)} ha  •  Applied: ${j.areaAppliedHaFor(_currentSwathWidthM()).toStringAsFixed(1)} ha  •  ${j.coveragePercentFor(_currentSwathWidthM()).toStringAsFixed(0)}%'),
              onTap: () async {
                Navigator.pop(ctx);
                await _showHistoryJobsFromPaths([j.filePath]);
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
              onLongPress: (tp, latlng) { if (_tool == EditorTool.drawOuter || _tool == EditorTool.drawHole) _finishDrawing(); },
              onMapReady: () {
                setState(() {
                  _mapReady = true;
                  _maybeAutoSelectPaddockFromGps();
                });
                _rebuildPaddockLayers();
                _runAfterMapFrame(() {
                  _applyMapRotation(0);
                  if (_followGps && _dispPos != null) {
                    _mapController.move(_dispPos!, _mapController.camera.zoom);
                    _lastCameraTarget = _dispPos;
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
              )
                  : TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: const ['a', 'b', 'c'],
                userAgentPackageName: 'pasturepath',
                maxNativeZoom: 19,
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
              if (_tool == EditorTool.drawOuter && _tempOuter.length >= 2)
                PolygonLayer(polygons: [
                  Polygon(
                    points: _tempOuter,
                    color: Theme.of(context).colorScheme.secondary.withOpacity(0.10),
                    borderColor: Theme.of(context).colorScheme.secondary,
                    borderStrokeWidth: 1.2,
                  )
                ]),

              // Temporary drawing preview (hole)
              if (_tool == EditorTool.drawHole && _tempHole.length >= 2)
                PolygonLayer(polygons: [
                  Polygon(
                    points: _tempHole,
                    color: Colors.red.withOpacity(0.06),
                    borderColor: Colors.red,
                    borderStrokeWidth: 1.2,
                    isFilled: true,
                  )
                ]),

              // Vertex drag handles when editing
              if (_tool == EditorTool.edit && _editingIdx != null)
                _editorEnabled ? _buildVertexEditor(_paddocks[_editingIdx!]) : const SizedBox.shrink(),

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

          // Editor toolbar
          _editorEnabled ? Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Theme.of(context).colorScheme.surface.withOpacity(0.90),
                elevation: 2,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _toolbarBtn('Draw', onTap: () {
                        setState(() {
                          _tool = EditorTool.drawOuter;
                          _tempOuter.clear();
                          _tempHole.clear();
                          _editingIdx = null;
                        });
                      }),
                      _toolbarBtn('Add hole', onTap: () {
                        final idx = _pickPaddockForEdit();
                        if (idx == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Tap a paddock first to select it')),);
                          return;
                        }
                        setState(() { _tool = EditorTool.drawHole; _editingIdx = idx; _tempHole.clear(); });
                      }),
                      _toolbarBtn('Edit verts', onTap: () {
                        final idx = _pickPaddockForEdit();
                        if (idx == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Tap a paddock to select it first')),);
                          return;
                        }
                        setState(() { _tool = EditorTool.edit; _editingIdx = idx; });
                      }),
                      _toolbarBtn('Undo', onTap: _undoLastPoint, enabled: _tool == EditorTool.drawOuter || _tool == EditorTool.drawHole),
                      _toolbarBtn('Finish', onTap: _finishDrawing, enabled: _tool == EditorTool.drawOuter || _tool == EditorTool.drawHole),
                      _toolbarBtn('Cancel', onTap: () { setState(() { _tool = EditorTool.none; _tempOuter.clear(); _tempHole.clear(); _editingIdx = null; }); }),
                    ],
                  ),
                ),
              ),
            ),
          ) : const SizedBox.shrink(),

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
            Positioned(
              right: _fabEdge,
              top: safe.top + _fabEdge,
              child: _fatRoundActionButton(
                icon: Icons.menu,
                diameter: _fabSecondaryDiameter,
                onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              ),
            ),
          ],

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
          if (_showFollowGpsButton)
            Positioned(
              right: _fabEdge,
              top: topChromeInset + _fabSecondaryDiameter + _fabGap,
              child: _fatRoundActionButton(
                icon: Icons.my_location,
                diameter: _fabSecondaryDiameter,
                onPressed: _recenter,
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
          if (!_navMode && !_showingHistory && _selectedIdx.isNotEmpty && _completedJobSummary == null) ...[
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

          // Completed job summary (top — keeps bottom controls clear)
          if (_completedJobSummary != null && !_navMode && !_showingHistory)
            Positioned(
              top: 0, left: 0, right: 0,
              child: _completedJobSummaryPanel(),
            ),

          // Historic job data panel
          if (_showingHistory && _activeHistoryJobs.isNotEmpty)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: _historyJobPanel(),
            ),
        ],
      ),
      ),
    );
  }
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
  });

  @override
  State<_HistoryJobPanel> createState() => _HistoryJobPanelState();
}

class _HistoryJobPanelState extends State<_HistoryJobPanel> with TickerProviderStateMixin {
  static const _panelPadding = EdgeInsets.fromLTRB(24, 24, 24, 180);

  late TabController _tabCtrl;
  AnimationController? _mapPanCtrl;
  int _lastPannedIndex = -1;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: widget.jobs.length, vsync: this);
    _tabCtrl.addListener(_onTabIndexChanged);
  }

  @override
  void didUpdateWidget(_HistoryJobPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobs.length != widget.jobs.length) {
      _lastPannedIndex = -1;
      _tabCtrl.removeListener(_onTabIndexChanged);
      _tabCtrl.dispose();
      _tabCtrl = TabController(length: widget.jobs.length, vsync: this);
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

  void _onTabIndexChanged() {
    if (_tabCtrl.indexIsChanging) return;
    final idx = _tabCtrl.index;
    if (idx == _lastPannedIndex) return;
    _lastPannedIndex = idx;
    _panToJob(widget.jobs[idx]);
  }

  void _panToJob(SavedJob job, {bool animate = true}) {
    if (!widget.mapReady) return;
    final bounds = _boundsForJob(job);
    if (bounds == null) return;

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
      duration: const Duration(milliseconds: 450),
    );
    final curved = CurvedAnimation(parent: _mapPanCtrl!, curve: Curves.easeInOut);
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

  @override
  Widget build(BuildContext context) {
    final jobs = widget.jobs;
    final scheme = Theme.of(context).colorScheme;

    return Material(
      elevation: 8,
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TabBar(
              controller: _tabCtrl,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              tabs: jobs.map((j) => Tab(text: _paddockTabLabel(j))).toList(),
            ),
            SizedBox(
              height: 140,
              child: TabBarView(
                controller: _tabCtrl,
                children: jobs.map((j) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
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
                        const SizedBox(height: 4),
                        Text(
                          j.id,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            _historyStat('Area', widget.areaText(j.totalHa)),
                            _historyStat('Applied', widget.areaText(widget.jobAreaAppliedHa(j))),
                            _historyStat('Coverage', '${widget.jobCoveragePercent(j).toStringAsFixed(0)}%'),
                            _historyStat('Swath', widget.jobSwathWidthText(j)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.formatDayHeader(DateTime(j.startedAt.year, j.startedAt.month, j.startedAt.day))}  ${widget.formatTime(j.startedAt)} – ${widget.formatTime(j.endedAt)}  •  ${j.avgSpeedKph.toStringAsFixed(1)} km/h',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
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

  const _ErrorChevronHud({
    required this.signedErrorM,
    required this.chevronsPerSide,
    required this.controller,
    required this.rowWidthMeters,
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