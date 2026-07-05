// lib/features/map/map_screen.dart
import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_dragmarker/flutter_map_dragmarker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/paddock.dart';
import '../../models/job.dart';
import '../../services/job_store.dart';
import '../../services/geometry.dart';
import '../../services/geojson_parser.dart';


enum EditorTool { none, drawOuter, drawHole, edit }



enum RotationMode { northUp, travelUp, free }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with SingleTickerProviderStateMixin {
  bool _editorEnabled = false;
  final MapController _mapController = MapController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  bool _mapReady = false;

  // Raw GPS
  LatLng? _currentPos;
  double? _currentHeadingDeg; // 0..360

  // Smoothed display state (for marker and camera)
  LatLng? _dispPos;
  double? _dispHeadingDeg;

  // Smoothing (0..1). Higher = snappier.
  static const double _posAlpha = 0.35;
  static const double _headingAlpha = 0.25;

  StreamSubscription<Position>? _posSub;

  // rotation / camera
  RotationMode _rotationMode = RotationMode.travelUp;

  // settings
  String _units = "meters";
  double _width = 3.0; // implement width (display units)
  double _offset = 0.0; // lateral offset (display units)
  Color _overlayColor = Colors.green;
  double _overlayOpacity = 0.20;
  Color _guidanceColor = Colors.red;
  bool _satellite = false;

  // heading (look-ahead) line
  Color _headingColor = Colors.blueAccent;
  double _headingLengthM = 12.0;
  double _headingWidth = 3.5;
  bool _headingDashed = false;

  // swath (travelled path)
  Color _swathColor = Colors.lightGreenAccent;
  double _swathOpacity = 0.55;

  // inputs
  late final TextEditingController _widthCtl;
  late final TextEditingController _offsetCtl;

  // paddocks
  List<Paddock> _paddocks = [];

  // selection
  final Set<int> _selectedIdx = <int>{};

  // nav
  bool _navMode = false;
  LatLng? _pointA;
  LatLng? _pointB;
  List<Polyline> _navLines = [];
  int _activeLineIndex = 0; // closest line index

  // look-ahead line
  Polyline? _lookAheadLine;

  // persistence
  String? _persistedJsonPath;

  // recording path & swath
  DateTime? _jobStartTime;
  List<LatLng> _jobPath = [];
  double _jobDistanceM = 0.0;
  final List<Polygon> _swathPolys = [];
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
  SavedJob? _activeHistoryJob;
  Polyline? _historyPathOverlay;

  // history multi-select in tab
  bool _histSelecting = false;
  final Set<String> _histSelected = <String>{};

  // Error HUD / chevrons
  double _signedErrorM = 0.0; // +ve steer right, -ve steer left
  late final AnimationController _chevCtrl;
  static const int _chevrons = 4; // avoids overflow; auto-sizes

  @override
  void initState() {
    super.initState();
    _widthCtl = TextEditingController(text: _width.toStringAsFixed(1))
      ..addListener(_applyWidthFromController);
    _offsetCtl = TextEditingController(text: _offset.toStringAsFixed(1))
      ..addListener(_applyOffsetFromController);

    // Smooth pulsing animation for chevrons
    _chevCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadPrefs();
      await _loadPersistedFarmJsonIfAny();
      await _ensureLocationFlow();
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _widthCtl.dispose();
    _offsetCtl.dispose();
    _chevCtrl.dispose();
    super.dispose();
  }

  // ---------- Prefs ----------
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _units = p.getString('units') ?? 'meters';
      _width = p.getDouble('width') ?? 3.0;
      _offset = p.getDouble('offset') ?? 0.0;
      _overlayOpacity = p.getDouble('overlayOpacity') ?? 0.20;
      final oc = p.getInt('overlayColor');
      final gc = p.getInt('guidanceColor');
      final hc = p.getInt('headingColor');
      final sc = p.getInt('swathColor');
      if (oc != null) _overlayColor = Color(oc);
      if (gc != null) _guidanceColor = Color(gc);
      if (hc != null) _headingColor = Color(hc);
      if (sc != null) _swathColor = Color(sc);
      _headingLengthM = p.getDouble('headingLengthM') ?? 12.0;
      _headingWidth = p.getDouble('headingWidth') ?? 3.5;
      _headingDashed = p.getBool('headingDashed') ?? false;
      _swathOpacity = p.getDouble('swathOpacity') ?? 0.55;
      _satellite = p.getBool('satellite') ?? false;
      final rm = p.getString('rotationMode');
      if (rm != null) {
        _rotationMode = RotationMode.values.firstWhere((e) => e.name == rm, orElse: () => RotationMode.travelUp);
      }
      _widthCtl.text = _width.toStringAsFixed(1);
      _offsetCtl.text = _offset.toStringAsFixed(1);
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('units', _units);
    await p.setDouble('width', _width);
    await p.setDouble('offset', _offset);
    await p.setDouble('overlayOpacity', _overlayOpacity);
    await p.setInt('overlayColor', _overlayColor.value);
    await p.setInt('guidanceColor', _guidanceColor.value);
    await p.setInt('headingColor', _headingColor.value);
    await p.setDouble('headingLengthM', _headingLengthM);
    await p.setDouble('headingWidth', _headingWidth);
    await p.setBool('headingDashed', _headingDashed);
    await p.setInt('swathColor', _swathColor.value);
    await p.setDouble('swathOpacity', _swathOpacity);
    await p.setBool('satellite', _satellite);
    await p.setString('rotationMode', _rotationMode.name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved settings')));
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
      });
      if (_paddocks.isNotEmpty && _mapReady) {
        _mapController.move(_paddocks.first.labelPoint, 16);
      }
    }
  }

  // ---------- Location ----------
  Future<void> _ensureLocationFlow() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enable Location Services')),
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission required')),
      );
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 10),
      );
      if (mounted) {
        setState(() {
          _currentPos = LatLng(pos.latitude, pos.longitude);
          _dispPos = _currentPos; // seed smoothing
          _currentHeadingDeg = pos.heading >= 0 ? pos.heading : null;
          _dispHeadingDeg = _currentHeadingDeg;
        });
      }
    } catch (_) {}

    _posSub?.cancel();
    final LocationSettings settings;
    if (io.Platform.isAndroid) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(milliseconds: 150),
        forceLocationManager: true,
      );
    } else if (io.Platform.isIOS) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        allowBackgroundLocationUpdates: false,
        pauseLocationUpdatesAutomatically: false,
        activityType: ActivityType.fitness,
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );
    }

    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen((p) {
      if (!mounted) return;

      // Raw
      final newPos = LatLng(p.latitude, p.longitude);
      final newHeading = p.heading >= 0 ? p.heading : _currentHeadingDeg;

      // Smoothed position (simple exponential smoothing in degrees)
      _dispPos = _dispPos == null ? newPos : _lerpLatLng(_dispPos!, newPos, _posAlpha);

      // Smooth heading with angular wrap-around lerp
      if (newHeading != null) {
        _dispHeadingDeg = _dispHeadingDeg == null
            ? newHeading
            : _lerpAngleDeg(_dispHeadingDeg!, newHeading, _headingAlpha);
      }

      _currentPos = newPos;
      _currentHeadingDeg = newHeading;

      // Recording swath uses smoothed position (visually nicer)
      if (_navMode && _dispPos != null) {
        _recordPathPoint(_dispPos!);
      }

      // Camera behavior uses smoothed pos/heading
      if (_mapReady && _dispPos != null) {
        switch (_rotationMode) {
          case RotationMode.northUp:
            if (_mapController.camera.rotation != 0) _mapController.rotate(0);
            break;
          case RotationMode.travelUp:
            if (_dispHeadingDeg != null) {
              final target = -_dispHeadingDeg!;
              final current = _mapController.camera.rotation;
              final smoothRot = _lerpAngleDeg(current, target, 0.25);
              _mapController.rotate(smoothRot);
            }
            break;
          case RotationMode.free:
            break;
        }
        if (_navMode) {
          _mapController.move(_dispPos!, _mapController.camera.zoom);
        }
      }

      _updateLookAhead();        // uses _dispPos/_dispHeadingDeg
      _updateActiveGuidanceLine();
      if (mounted) setState(() {});
    });
  }

  // ---------- Math helpers ----------
  LatLng _lerpLatLng(LatLng a, LatLng b, double t) {
    return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
  }

  double _normalizeAngleDeg(double d) {
    var x = d % 360.0;
    if (x < 0) x += 360.0;
    return x;
  }

  double _lerpAngleDeg(double a, double b, double t) {
    a = _normalizeAngleDeg(a);
    b = _normalizeAngleDeg(b);
    var diff = b - a;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return _normalizeAngleDeg(a + diff * t);
  }

  // ---------- Helpers ----------
  double _toMeters(double v) => _units == 'feet' ? v / 3.280839895 : v;
  String _lenUnit() => _units == 'feet' ? 'ft' : 'm';
  String _areaText(double ha) => _units == 'feet'
      ? '${(ha * 2.47105).toStringAsFixed(1)} ac'
      : '${ha.toStringAsFixed(1)} ha';

  void _applyWidthFromController() {
    final v = double.tryParse(_widthCtl.text.replaceAll(',', '.'));
    if (v != null && v > 0 && v != _width) setState(() => _width = v);
  }

  void _applyOffsetFromController() {
    final v = double.tryParse(_offsetCtl.text.replaceAll(',', '.'));
    if (v != null && v != _offset) setState(() => _offset = v);
  }

  bool get _canRecenter {
    if (_dispPos == null || !_mapReady) return false;
    final cam = _mapController.camera;
    final d = const Distance().as(LengthUnit.Meter, cam.center, _dispPos!);
    return d > 60;
  }

  void _recenter() {
    if (_dispPos != null && _mapReady) {
      _mapController.move(_dispPos!, _mapController.camera.zoom);
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
    _savePrefs();
    if (_mapReady) {
      if (_rotationMode == RotationMode.northUp) _mapController.rotate(0);
      if (_rotationMode == RotationMode.travelUp && _dispHeadingDeg != null) {
        _mapController.rotate(-_dispHeadingDeg!);
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
  LatLng _centroidOuter(List<LatLng> ring) {
    double a = 0, cx = 0, cy = 0;
    for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i].longitude, yi = ring[i].latitude;
      final xj = ring[j].longitude, yj = ring[j].latitude;
      final f = xi * yj - xj * yi;
      a += f;
      cx += (xi + xj) * f;
      cy += (yi + yj) * f;
    }
    if (a.abs() < 1e-9) return ring.first;
    a *= 0.5;
    cx /= (6 * a);
    cy /= (6 * a);
    return LatLng(cy, cx);
  }

  LatLng _safeLabelPoint(Paddock pd) {
    // Prefer provided label point if it's inside
    if (pointInPolygon(pd.labelPoint, pd.outer, pd.holes)) return pd.labelPoint;

    // Centroid fallback
    final c = _centroidOuter(pd.outer);
    if (pointInPolygon(c, pd.outer, pd.holes)) return c;

    // Midpoint of longest edge
    double best = -1;
    LatLng bestMid = pd.outer.first;
    for (int i = 0; i < pd.outer.length - 1; i++) {
      final a = pd.outer[i], b = pd.outer[i + 1];
      final d = const Distance().as(LengthUnit.Meter, a, b);
      if (d > best) {
        best = d;
        bestMid = LatLng((a.latitude + b.latitude) * 0.5, (a.longitude + b.longitude) * 0.5);
      }
    }
    if (pointInPolygon(bestMid, pd.outer, pd.holes)) return bestMid;

    return pd.outer.first;
  }

  // ---------- Swath builder ----------
  void _recordPathPoint(LatLng p) {
    if (_jobPath.isEmpty) {
      _jobPath.add(p);
      return;
    }
    final last = _jobPath.last;
    final d = const Distance().as(LengthUnit.Meter, last, p);
    if (d < 0.35) return; // threshold to reduce flicker rectangles

    _jobPath.add(p);
    _jobDistanceM += d;

    // Build a quad (strip of working width) centered on segment (last->p)
    const Rm = 111320.0;
    final lat0 = ((last.latitude + p.latitude) * 0.5) * math.pi / 180.0;
    final dE = (p.longitude - last.longitude) * Rm * math.cos(lat0);
    final dN = (p.latitude - last.latitude) * Rm;
    final len = math.sqrt(dE * dE + dN * dN);
    if (len == 0) return;

    final tE = dE / len;
    final tN = dN / len;
    final nE = -tN;
    final nN =  tE;

    final wM = (_toMeters(_width) <= 0) ? 3.0 : _toMeters(_width);
    final half = wM * 0.5;

    final lastL = _offsetMeters(last, -nE * half, -nN * half);
    final lastR = _offsetMeters(last,  nE * half,  nN * half);
    final currL = _offsetMeters(p,    -nE * half, -nN * half);
    final currR = _offsetMeters(p,     nE * half,  nN * half);

    if (_selectedIdx.isNotEmpty && (!_inSelectedPaddock(last) || !_inSelectedPaddock(p))) {
      return;
    }

    _swathPolys.add(Polygon(
      points: [lastL, lastR, currR, currL],
      color: _swathColor.withOpacity(_swathOpacity),
      borderColor: Colors.transparent,
      borderStrokeWidth: 0.0,
      isFilled: true,
      isDotted: false,
    ));

    if (_swathPolys.length > 20000) {
      _swathPolys.removeRange(0, _swathPolys.length - 20000);
    }
  }

  // ---------- Look-ahead line ----------
  void _updateLookAhead() {
    if (_dispPos == null) { setState(() => _lookAheadLine = null); return; }
    final heading = (_dispHeadingDeg ?? 0.0) * math.pi / 180.0;
    final lookM = _headingLengthM.clamp(1.0, 200.0);

    final northM = lookM * math.cos(heading);
    final eastM = lookM * math.sin(heading);
    final end = _offsetMeters(_dispPos!, eastM, northM);

    List<List<LatLng>> segs;
    if (_selectedIdx.isNotEmpty) {
      final all = <List<LatLng>>[];
      for (final i in _selectedIdx) {
        final pd = _paddocks[i];
        all.addAll(clipLineABToPolygonExact(_dispPos!, end, pd.outer, pd.holes));
      }
      segs = all;
    } else {
      segs = [[_dispPos!, end]];
    }
    if (segs.isEmpty) { setState(() => _lookAheadLine = null); return; }

    _lookAheadLine = Polyline(
      points: segs.first,
      strokeWidth: _headingWidth.clamp(2.0, 12.0),
      color: _headingColor.withOpacity(0.95),
      isDotted: _headingDashed,
    );
  }

  // ---------- Guidance generation & closest active line ----------
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

    final polylines = <Polyline>[];

    void addParallel(double kMeters, {required bool solid}) {
      final baseA = offsetM(aOff, nE * kMeters, nN * kMeters);
      final baseB = offsetM(bOff, nE * kMeters, nN * kMeters);

      const L = 12000.0; // extend so clipping hits boundary tidily
      final extA = offsetM(baseA, -tE * L, -tN * L);
      final extB = offsetM(baseB,  tE * L,  tN * L);

      final segs = clipJob(extA, extB);
      for (final s in segs) {
        polylines.add(Polyline(
          points: s,
          color: _guidanceColor,
          strokeWidth: solid ? 4.0 : 2.2,
          isDotted: !solid,
        ));
      }
    }

    // centerline
    addParallel(0, solid: true);

    final maxSpan = _selectedIdx.isEmpty ? _approxSpanMeters(_mapController.camera.visibleBounds) : 2500.0;
    for (double k = widthM; k <= maxSpan; k += widthM) {
      addParallel( k, solid: false);
      addParallel(-k, solid: false);
    }

    setState(() {
      _navLines = polylines;
      _activeLineIndex = 0;
    });
  }

  void _updateActiveGuidanceLine() {
    if (_dispPos == null || _navLines.isEmpty) return;
    final p = _dispPos!;
    double best = double.infinity;
    int bestIdx = 0;
    for (int i = 0; i < _navLines.length; i++) {
      final d = distancePointToPolylineMeters(p, _navLines[i].points);
      if (d < best) { best = d; bestIdx = i; }
    }

    // Signed error vs best line
    final signed = _signedDistanceToPolylineMeters(p, _navLines[bestIdx].points);
    _signedErrorM = signed;

    if (bestIdx != _activeLineIndex) {
      _activeLineIndex = bestIdx;
      for (int i = 0; i < _navLines.length; i++) {
        final base = _navLines[i];
        _navLines[i] = Polyline(
          points: base.points,
          color: _guidanceColor,
          strokeWidth: i == _activeLineIndex ? 4.0 : 2.2,
          isDotted: i == _activeLineIndex ? false : true,
        );
      }
    }
  }

  double _signedDistanceToPolylineMeters(LatLng p, List<LatLng> line) {
    if (line.length < 2) return double.infinity;
    double best = double.infinity;
    double bestSign = 0.0;

    for (int i = 0; i < line.length - 1; i++) {
      final a = line[i];
      final b = line[i + 1];

      const Rm = 111320.0;
      final lat0 = ((a.latitude + b.latitude) * 0.5) * math.pi / 180.0;
      final ax = a.longitude * Rm * math.cos(lat0), ay = a.latitude * Rm;
      final bx = b.longitude * Rm * math.cos(lat0), by = b.latitude * Rm;
      final px = p.longitude * Rm * math.cos(lat0), py = p.latitude * Rm;

      final vx = bx - ax, vy = by - ay;
      final wx = px - ax, wy = py - ay;

      final c1 = vx * wx + vy * wy;
      final c2 = vx * vx + vy * vy;

      double hx, hy;
      if (c1 <= 0) {
        hx = ax; hy = ay;
      } else if (c2 <= c1) {
        hx = bx; hy = by;
      } else {
        final t = c1 / c2;
        hx = ax + t * vx; hy = ay + t * vy;
      }

      final dx = px - hx, dy = py - hy;
      final d = math.sqrt(dx * dx + dy * dy);

      final sx = hx - ax, sy = hy - ay;
      final crossZ = sx * (py - hy) - sy * (px - hx);
      final sign = crossZ >= 0 ? 1.0 : -1.0;

      if (d < best) {
        best = d;
        bestSign = sign;
      }
    }
    return best * bestSign;
  }

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
      _navMode = false;
      _navLines = [];
      _pointA = null;
      _pointB = null;
      _lookAheadLine = null;
      _swathPolys.clear();
    });

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
          _selectedIdx
            ..clear()
            ..add(hit);
        });
      } else {
        setState(() => _selectedIdx.clear());
      }
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
    final c = _centroid(outer);
    if (pointInPolygon(c, outer, holes)) return c;
    const step = 0.0002; // ~20m
    final cands = [
      LatLng(c.latitude + step, c.longitude),
      LatLng(c.latitude - step, c.longitude),
      LatLng(c.latitude, c.longitude + step),
      LatLng(c.latitude, c.longitude - step),
      LatLng(c.latitude + step, c.longitude + step),
      LatLng(c.latitude - step, c.longitude - step),
    ];
    for (final p in cands) { if (pointInPolygon(p, outer, holes)) return p; }
    return outer.first;
  }
// ---------- Job flow ----------
  Future<void> _startNavigation() async {
    if (_selectedIdx.isEmpty) return;
    setState(() {
      _navMode = true;
      _pointA = null;
      _pointB = null;
      _navLines = [];
      _lookAheadLine = null;
      _jobPath = [];
      _jobDistanceM = 0.0;
      _swathPolys.clear();
      _showingHistory = false;
      _activeHistoryJob = null;
      _historyPathOverlay = null;
      _histSelecting = false;
      _histSelected.clear();
      _jobStartTime = DateTime.now();
    });

    if (_mapReady && _dispPos != null) {
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
  }

  Future<void> _finishJob() async {
    if (!_navMode || _jobStartTime == null || _jobPath.length < 2) {
      setState(() { _navMode = false; });
      return;
    }
    final end = DateTime.now();
    final durHrs = end.difference(_jobStartTime!).inMilliseconds / 3600000.0;
    final avgKph = durHrs > 0 ? (_jobDistanceM / 1000.0) / durHrs : 0.0;

    final names = _selectedIdx.map((i) => _paddocks[i].name).toList()..sort();
    final totalHa = _selectedIdx.fold(0.0, (s, i) => s + _paddocks[i].areaHa);

    final n = await JobStore.nextSequenceForDay(end);
    final id = JobStore.dayTitle(end, n);

    final job = SavedJob(
      id: id,
      startedAt: _jobStartTime!,
      endedAt: end,
      path: List<LatLng>.from(_jobPath),
      paddockNames: names,
      totalHa: totalHa,
      avgSpeedKph: avgKph,
    );
    await JobStore.save(job);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved: $id')));

    setState(() {
      _navMode = false; // hides error HUD
      _pointA = null;
      _pointB = null;
      _navLines.clear();
      _lookAheadLine = null;
      _swathPolys.clear();
    });
  }

  void _markA() {
    if (_dispPos == null) return;
    setState(() {
      _pointA = _dispPos;
      _pointB = null;
      _navLines = [];
    });
  }

  void _markB() {
    if (_dispPos == null || _pointA == null) return;
    setState(() => _pointB = _dispPos);
    _buildGuidance(_pointA!, _pointB!);
  }

  // ---------- UI: Drawer ----------
  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              const TabBar(tabs: [
                Tab(text: 'Settings'),
                Tab(text: 'Historic Jobs'),
              ]),
              Expanded(
                child: TabBarView(
                  children: [
                    _settingsTab(),
                    _historyTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _settingsTab() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const ListTile(title: Text('Map & Tiles', style: TextStyle(fontWeight: FontWeight.bold))),
        SwitchListTile(
          title: const Text('Satellite view (Esri)'),
          value: _satellite,
          onChanged: (v) => setState(() => _satellite = v),
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
                _navLines = [];
                _pointA = null;
                _pointB = null;
                _lookAheadLine = null;
                _swathPolys.clear();
              });
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

        const ListTile(title: Text('Units & Implement', style: TextStyle(fontWeight: FontWeight.bold))),
        RadioListTile<String>(
          title: const Text('Metric (m, ha)'),
          value: 'meters',
          groupValue: _units,
          onChanged: (v) => setState(() => _units = v!),
        ),
        RadioListTile<String>(
          title: const Text('Imperial (ft, ac)'),
          value: 'feet',
          groupValue: _units,
          onChanged: (v) => setState(() => _units = v!),
        ),
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: const Text('Working width'),
          subtitle: Text(_lenUnit()),
          trailing: SizedBox(
            width: 120,
            child: TextField(
              controller: _widthCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: false),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*([.,]\d*)?$'))],
              decoration: const InputDecoration(isDense: true, hintText: 'e.g. 3.0'),
              onSubmitted: (_) => _savePrefs(),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('Offset from centre'),
          subtitle: Text(_lenUnit()),
          trailing: SizedBox(
            width: 120,
            child: TextField(
              controller: _offsetCtl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*([.,]\d*)?$'))],
              decoration: const InputDecoration(isDense: true, hintText: 'e.g. 0.0'),
              onSubmitted: (_) => _savePrefs(),
            ),
          ),
        ),
        const Divider(),

        const ListTile(title: Text('Overlay & Guidance', style: TextStyle(fontWeight: FontWeight.bold))),
        ListTile(
          title: const Text('Paddock fill transparency'),
          subtitle: Slider(
            value: _overlayOpacity, min: 0.0, max: 0.60, divisions: 60,
            label: _overlayOpacity.toStringAsFixed(2),
            onChanged: (v) => setState(() => _overlayOpacity = v),
          ),
        ),
        _colorRow(
          label: 'Overlay colour',
          current: _overlayColor,
          options: const [Colors.green, Colors.blue, Colors.orange, Colors.purple, Colors.red, Colors.teal],
          onPick: (c) => setState(() => _overlayColor = c),
        ),
        const SizedBox(height: 8),
        _colorRow(
          label: 'Guidance colour',
          current: _guidanceColor,
          options: const [Colors.red, Colors.blue, Colors.cyan, Colors.lime, Colors.amber, Colors.white, Colors.black],
          onPick: (c) => setState(() => _guidanceColor = c),
        ),
        const Divider(),

        const ListTile(title: Text('Heading Line', style: TextStyle(fontWeight: FontWeight.bold))),
        _colorRow(
          label: 'Heading line colour',
          current: _headingColor,
          options: const [Colors.blueAccent, Colors.white, Colors.yellow, Colors.orange, Colors.pink, Colors.black],
          onPick: (c) => setState(() => _headingColor = c),
        ),
        ListTile(
          title: const Text('Heading line length (m)'),
          subtitle: Slider(
            value: _headingLengthM, min: 4.0, max: 30.0, divisions: 26,
            label: _headingLengthM.toStringAsFixed(0),
            onChanged: (v) => setState(() => _headingLengthM = v),
          ),
        ),
        ListTile(
          title: const Text('Heading line width'),
          subtitle: Slider(
            value: _headingWidth, min: 2.0, max: 8.0, divisions: 12,
            label: _headingWidth.toStringAsFixed(1),
            onChanged: (v) => setState(() => _headingWidth = v),
          ),
        ),
        SwitchListTile(
          title: const Text('Heading line dashed'),
          value: _headingDashed,
          onChanged: (v) => setState(() => _headingDashed = v),
        ),
        const Divider(),

        const ListTile(title: Text('Travelled Swath', style: TextStyle(fontWeight: FontWeight.bold))),
        _colorRow(
          label: 'Swath colour',
          current: _swathColor,
          options: const [Colors.lightGreenAccent, Colors.cyanAccent, Colors.amber, Colors.pinkAccent, Colors.white, Colors.black],
          onPick: (c) => setState(() => _swathColor = c),
        ),
        ListTile(
          title: const Text('Swath opacity'),
          subtitle: Slider(
            value: _swathOpacity, min: 0.1, max: 0.9, divisions: 80,
            label: _swathOpacity.toStringAsFixed(2),
            onChanged: (v) => setState(() => _swathOpacity = v),
          ),
        ),

        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ElevatedButton.icon(
            onPressed: _savePrefs,
            icon: const Icon(Icons.save),
            label: const Text('Save settings'),
          ),
        ),
      ],
    );
  }

  Widget _colorRow({
    required String label,
    required Color current,
    required List<Color> options,
    required void Function(Color) onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(label)),
          Expanded(
            child: Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                for (final c in options)
                  GestureDetector(
                    onTap: () => onPick(c),
                    child: Container(
                      width: 26, height: 26,
                      decoration: BoxDecoration(
                        color: c.withOpacity(c == current ? 1.0 : 0.9),
                        border: Border.all(
                          color: c.computeLuminance() > 0.5 ? Colors.black54 : Colors.white,
                          width: c == current ? 3 : 1.2,
                        ),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyTab() {
    return FutureBuilder<List<String>>(
      future: JobStore.listJobFiles(),
      builder: (context, snap) {
        final files = snap.data ?? const [];
        if (files.isEmpty) return const Center(child: Text('No jobs saved yet.'));
        return Column(
          children: [
            if (_histSelecting)
              Material(
                elevation: 2,
                child: ListTile(
                  leading: Text('${_histSelected.length} selected'),
                  title: Row(
                    children: [
                      IconButton(
                        tooltip: 'Export GPX',
                        onPressed: _histSelected.isEmpty ? null : () async {
                          final path = await JobStore.exportGpx(_histSelected.toList());
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported GPX: ${path.split('/').last}')));
                          await JobStore.shareFile(path);
                        },
                        icon: const Icon(Icons.route),
                      ),
                      IconButton(
                        tooltip: 'Export GeoJSON',
                        onPressed: _histSelected.isEmpty ? null : () async {
                          final path = await JobStore.exportGeoJson(_histSelected.toList());
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Exported GeoJSON: ${path.split('/').last}')));
                          await JobStore.shareFile(path);
                        },
                        icon: const Icon(Icons.map),
                      ),
                      IconButton(
                        tooltip: 'Delete',
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
                            setState(() { _histSelecting = false; _histSelected.clear(); });
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deleted')));
                          }
                        },
                        icon: const Icon(Icons.delete),
                      ),
                      const Spacer(),
                      TextButton(onPressed: () => setState(() { _histSelecting = false; _histSelected.clear(); }), child: const Text('Clear'))
                    ],
                  ),
                ),
              ),
            Expanded(
              child: ListView.separated(
                itemCount: files.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final base = files[i].split('/').last.split('\\').last;
                  final title = base.replaceAll('.json', '').replaceAll('-', '/');
                  final selected = _histSelected.contains(files[i]);
                  return ListTile(
                    leading: const Icon(Icons.timeline),
                    title: Text(title),
                    trailing: _histSelecting
                        ? Checkbox(value: selected, onChanged: (_) {
                      setState(() {
                        if (selected) { _histSelected.remove(files[i]); } else { _histSelected.add(files[i]); }
                      });
                    })
                        : null,
                    onTap: () async {
                      if (_histSelecting) {
                        setState(() {
                          if (selected) { _histSelected.remove(files[i]); } else { _histSelected.add(files[i]); }
                        });
                        return;
                      }
                      final job = await JobStore.read(files[i]);
                      _showHistoryJob(job);
                      if (mounted) Navigator.of(context).maybePop();
                    },
                    onLongPress: () {
                      setState(() {
                        _histSelecting = true;
                        _histSelected.clear();
                        _histSelected.add(files[i]);
                      });
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _showHistoryJob(SavedJob job) {
    final poly = Polyline(points: job.path, strokeWidth: 3.0, color: Colors.deepPurpleAccent);
    setState(() {
      _showingHistory = true;
      _activeHistoryJob = job;
      _historyPathOverlay = poly;
      _navMode = false;
      _selectedIdx.clear();
      _navLines.clear();
      _lookAheadLine = null;
    });

    if (_mapReady && job.path.isNotEmpty) {
      final lats = job.path.map((e) => e.latitude).toList();
      final lngs = job.path.map((e) => e.longitude).toList();
      final south = lats.reduce(math.min);
      final north = lats.reduce(math.max);
      final west = lngs.reduce(math.min);
      final east = lngs.reduce(math.max);
      _mapController.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds(LatLng(south, west), LatLng(north, east)),
        padding: const EdgeInsets.all(24),
      ));
    }
  }

  void _exitHistory() {
    setState(() {
      _showingHistory = false;
      _activeHistoryJob = null;
      _historyPathOverlay = null;
    });
  }

  Future<void> _showPaddockHistory(String paddockName) async {
    final files = await JobStore.listJobFiles();
    final rows = <SavedJob>[];
    for (final f in files) {
      final j = await JobStore.read(f);
      if (j.paddockNames.contains(paddockName)) rows.add(j);
    }
    rows.sort((a, b) => b.startedAt.compareTo(a.startedAt));

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
              subtitle: Text('Area: ${j.totalHa.toStringAsFixed(1)} ha  •  Avg: ${j.avgSpeedKph.toStringAsFixed(1)} km/h'),
              onTap: () {
                _showHistoryJob(j);
                Navigator.pop(ctx);
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

    // Cursor marker (circle)
    final gpsMarkers = <Marker>[];
    if (_dispPos != null && !_showingHistory) {
      gpsMarkers.add(
        Marker(
          point: _dispPos!,
          width: 22, height: 22, alignment: Alignment.center,
          child: Container(
            width: 18, height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blue.withOpacity(0.95),
              border: Border.all(color: Colors.white, width: 2.3),
              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
            ),
          ),
        ),
      );
    }

    // Polygons & labels
    final List<Polygon> pdkPolys = [];
    final List<Marker> pdkLabels = [];
    for (int i = 0; i < _paddocks.length; i++) {
      final pd = _paddocks[i];
      final isSel = _selectedIdx.contains(i);
      pdkPolys.add(
        Polygon(
          points: pd.outer,
          holePointsList: pd.holes,
          color: _overlayColor.withOpacity((_overlayOpacity + (isSel ? 0.08 : 0.0)).clamp(0.0, 1.0)),
          borderColor: isSel ? Colors.yellow.shade700 : _overlayColor,
          borderStrokeWidth: isSel ? 3.5 : 2.0,
          isFilled: true,
        ),
      );
      final zoom = _mapReady ? _mapController.camera.zoom : 0.0;
      if (zoom >= 15.0) {
        final labelAnchor = _safeLabelPoint(pd);
        pdkLabels.add(
          Marker(
            point: labelAnchor,
            width: 200,
            height: 52,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(pd.name, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Colors.black87)),
                Text(_areaText(pd.areaHa), textAlign: TextAlign.center, style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 11, color: Colors.black54)),
              ],
            ),
          ),
        );
      }
    }

    // Job selection summary + paddock name for history
    final double totalHa = _selectedIdx.fold(0.0, (s, i) => s + _paddocks[i].areaHa);
    final List<String> selectedNames = _selectedIdx.map((i) => _paddocks[i].name).toList()..sort();
    final String jobTitle = selectedNames.join(', ');
    final String? singleSelectedName = _selectedIdx.length == 1 ? _paddocks[_selectedIdx.first].name : null;

    return Scaffold(
      key: _scaffoldKey,
      appBar: _navMode ? null : AppBar(
        titleSpacing: 0,
        title: Row(children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Image.asset('assets/logo.png', height: 28, errorBuilder: (_, __, ___) => const Icon(Icons.agriculture)),
          ),
          const Text('PasturePath'),
        ]),
        leading: _showingHistory ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _exitHistory) : null,
        actions: [
          IconButton(icon: const Icon(Icons.menu), onPressed: () => _scaffoldKey.currentState?.openEndDrawer()),
        ],
      ),
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
              onMapReady: () => setState(() => _mapReady = true),
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
              if (pdkPolys.isNotEmpty) PolygonLayer(polygons: pdkPolys),

              // Swath ABOVE paddocks so it's visible
              if (_navMode && _swathPolys.isNotEmpty) PolygonLayer(polygons: _swathPolys),

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
              if (pdkLabels.isNotEmpty) MarkerLayer(markers: pdkLabels, rotate: true),

              if (_navLines.isNotEmpty) PolylineLayer(polylines: _navLines),
              if (_lookAheadLine != null) PolylineLayer(polylines: [_lookAheadLine!]),
              if (_historyPathOverlay != null) PolylineLayer(polylines: [_historyPathOverlay!]),

              if (gpsMarkers.isNotEmpty) MarkerLayer(markers: gpsMarkers),
            ],
          ),

          // Editor toolbar
          _editorEnabled ? Positioned(
            top: 12,
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

          // Error HUD (top-center) – only in nav mode
          if (_navMode)
            Positioned(
              top: 0 + safe.top,
              left: 0, right: 0,
              child: Center(
                child: _ErrorChevronHud(
                  signedErrorM: _signedErrorM,
                  chevronsPerSide: _chevrons,
                  controller: _chevCtrl,
                  rowWidthMeters: _toMeters(_width <= 0 ? 3.0 : _width),
                ),
              ),
            ),

          // Rotation toggle (moved down to avoid error bar)
          Positioned(
            right: 12, top: safe.top + 76,
            child: FloatingActionButton(
              heroTag: 'rotateMode',
              mini: true,
              onPressed: _cycleRotationMode,
              tooltip: 'Map rotation',
              child: Icon(_rotationIcon()),
            ),
          ),

          // Recenter under rotation button
          if (_canRecenter && !_showingHistory)
            Positioned(
              right: 12, top: safe.top + 76 + 56,
              child: FloatingActionButton(
                heroTag: 'recenter',
                mini: true,
                onPressed: _recenter,
                child: const Icon(Icons.my_location),
              ),
            ),

          // A/B buttons (bottom-right)
          if (_navMode && _pointA == null && _dispPos != null)
            Positioned(
              right: 16, bottom: 16 + MediaQuery.of(context).padding.bottom,
              child: FloatingActionButton.extended(
                heroTag: 'markA',
                onPressed: _markA,
                icon: const CircleAvatar(radius: 10, child: Text('A')),
                label: const Text('Mark A'),
              ),
            ),
          if (_navMode && _pointA != null && _pointB == null && _dispPos != null)
            Positioned(
              right: 16, bottom: 16 + MediaQuery.of(context).padding.bottom,
              child: FloatingActionButton.extended(
                heroTag: 'markB',
                onPressed: _markB,
                icon: const CircleAvatar(radius: 10, child: Text('B')),
                label: const Text('Mark B'),
              ),
            ),

          // Finish job (round FAB – opposite A/B)
          if (_navMode)
            Positioned(
              left: 16,
              bottom: 16 + MediaQuery.of(context).padding.bottom,
              child: FloatingActionButton(
                heroTag: 'finishJob',
                onPressed: _finishJob,
                tooltip: 'Finish Job',
                child: const Icon(Icons.flag),
              ),
            ),

          // Job selection bar + paddock history button
          if (!_navMode && !_showingHistory && _selectedIdx.isNotEmpty)
            Positioned(
              left: 0, right: 0, bottom: 0,
              child: SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  color: Colors.white.withOpacity(0.96),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Job: $jobTitle',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _units == 'feet'
                                ? '${(totalHa * 2.47105).toStringAsFixed(1)} ac'
                                : '${totalHa.toStringAsFixed(1)} ha',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (singleSelectedName != null)
                            OutlinedButton.icon(
                              onPressed: () => _showPaddockHistory(singleSelectedName),
                              icon: const Icon(Icons.history),
                              label: const Text('History'),
                            ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => setState(() => _selectedIdx.clear()),
                            child: const Text('Clear'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: _startNavigation,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Text('Start Navigation'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
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