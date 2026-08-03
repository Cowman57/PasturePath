import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:usb_serial/usb_serial.dart';

import '../../models/gps_fix.dart';
import 'device_gps_source.dart';
import 'gps_source.dart';
import 'usb_serial_gps_source.dart';

/// Selects and runs the active GPS source; exposes a single [fixes] stream.
class GpsInputController extends ChangeNotifier {
  GpsInputController({GpsInputMode mode = GpsInputMode.auto}) : _mode = mode;

  static const int defaultBaudRate = 115200;
  static const Duration _usbEventDebounce = Duration(milliseconds: 450);

  GpsInputMode _mode;
  GpsActiveSource _active = GpsActiveSource.none;
  String _statusMessage = 'Starting…';
  String? _deviceLabel;
  DateTime? _lastFixAt;
  String? _lastError;
  String? _connectionHint;

  int? _satellites;
  double? _accuracyM;
  double _fixHz = 0;
  /// Receive times of unique NMEA/device epochs (not every RMC+GGA+GLL line).
  final List<DateTime> _epochReceiveTimes = <DateTime>[];
  int? _lastEpochKey;
  int? _publishedSats;
  double? _publishedAcc;
  double _publishedHz = -1;
  String? _publishedHint;

  final _fixesController = StreamController<GpsFix>.broadcast();
  final DeviceGpsSource _device = DeviceGpsSource();
  UsbSerialGpsSource? _usb;

  StreamSubscription<GpsFix>? _sourceSub;
  StreamSubscription<UsbEvent>? _usbEventSub;
  Timer? _qualityTimer;
  Timer? _usbDebounce;
  bool _started = false;
  bool _switching = false;
  bool _pendingApply = false;
  List<UsbDeviceInfo> _devices = const [];

  GpsInputMode get mode => _mode;
  GpsActiveSource get activeSource => _active;
  String get statusMessage => _statusMessage;
  String? get deviceLabel => _deviceLabel;
  DateTime? get lastFixAt => _lastFixAt;
  String? get lastError => _lastError;
  /// Short non-spammy hint when waiting / failing (no NMEA dump).
  String? get connectionHint => _connectionHint;
  int? get satellites => _satellites;
  double? get accuracyM => _accuracyM;
  double get fixHz => _fixHz;
  List<UsbDeviceInfo> get devices => _devices;
  Stream<GpsFix> get fixes => _fixesController.stream;

  bool get isUsbActive => _active == GpsActiveSource.usb;
  bool get usbSupported => UsbSerialGpsSource.isPlatformSupported;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await refreshDevices();
    _usbEventSub = UsbSerialGpsSource.listenUsbEvents((_) {
      _scheduleUsbTopologyApply();
    });
    await _applySelection(reason: 'start');
  }

  Future<void> setMode(GpsInputMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    if (_started) await _applySelection(reason: 'mode');
  }

  Future<void> refreshDevices() async {
    _devices = await UsbSerialGpsSource.listDevices();
    notifyListeners();
  }

  Future<void> reconnect() async {
    if (!_started) return;
    await refreshDevices();
    await _applySelection(reason: 'reconnect');
  }

  void _scheduleUsbTopologyApply() {
    _usbDebounce?.cancel();
    _usbDebounce = Timer(_usbEventDebounce, () {
      unawaited(_onUsbTopologyChanged());
    });
  }

  Future<void> _onUsbTopologyChanged() async {
    if (!_started) return;
    await refreshDevices();
    if (_mode == GpsInputMode.device) return;
    await _applySelection(reason: 'usb-event');
  }

  Future<void> _applySelection({required String reason}) async {
    if (_switching) {
      _pendingApply = true;
      return;
    }
    _switching = true;
    try {
      while (true) {
        _pendingApply = false;

        final wantUsb = _shouldUseUsb();
        if (wantUsb) {
          final ok = await _startUsb();
          if (!ok) {
            if (_mode == GpsInputMode.usb) {
              await _stopActiveSource();
              _active = GpsActiveSource.none;
              _statusMessage = _lastError ?? 'USB GPS unavailable';
              notifyListeners();
            } else {
              await _startDevice();
            }
          }
        } else {
          await _startDevice();
        }

        if (!_pendingApply) break;
      }
    } finally {
      _switching = false;
    }
  }

  bool _shouldUseUsb() {
    if (!usbSupported) return false;
    switch (_mode) {
      case GpsInputMode.device:
        return false;
      case GpsInputMode.usb:
        return true;
      case GpsInputMode.auto:
        return _devices.isNotEmpty;
    }
  }

  Future<bool> _startUsb() async {
    await refreshDevices();
    if (_devices.isEmpty) {
      _lastError = 'No USB serial GPS connected';
      return false;
    }

    await _stopActiveSource();
    final src = UsbSerialGpsSource(baudRate: defaultBaudRate);
    try {
      await src.start();
      _usb = src;
      _active = GpsActiveSource.usb;
      _deviceLabel = src.label;
      _lastError = null;
      final driver = src.openedDriverType ?? 'auto';
      final vidPid = src.connectedVidPid ?? '';
      _statusMessage =
          'USB connected · $_deviceLabel'
          '${vidPid.isEmpty ? '' : ' · $vidPid'} · $driver';
      _connectionHint = 'Waiting for fix…';
      _resetQuality();
      _listenSource(src.fixes);
      _startQualityTimer();
      notifyListeners();
      return true;
    } catch (e) {
      await src.stop();
      _usb = null;
      _lastError = e.toString().replaceFirst('Bad state: ', '');
      _statusMessage = _lastError!;
      _connectionHint = _lastError;
      notifyListeners();
      return false;
    }
  }

  Future<void> _startDevice() async {
    await _stopActiveSource();
    try {
      await _device.start();
      _active = GpsActiveSource.device;
      _deviceLabel = null;
      _lastError = null;
      _statusMessage = 'Using device GPS';
      _connectionHint = 'Waiting for fix…';
      _resetQuality();
      _listenSource(_device.fixes);
      _startQualityTimer();
      notifyListeners();
    } catch (e) {
      _active = GpsActiveSource.none;
      _lastError = e.toString().replaceFirst('Bad state: ', '');
      _statusMessage = _lastError!;
      _connectionHint = _lastError;
      notifyListeners();
    }
  }

  void _resetQuality() {
    _satellites = null;
    _accuracyM = null;
    _fixHz = 0;
    _epochReceiveTimes.clear();
    _lastEpochKey = null;
    _lastFixAt = null;
    _connectionHint = null;
    _publishedSats = null;
    _publishedAcc = null;
    _publishedHz = -1;
    _publishedHint = null;
  }

  void _startQualityTimer() {
    _qualityTimer?.cancel();
    _qualityTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _publishQuality();
    });
  }

  /// USB modules often emit RMC+GGA(+GLL) each epoch → 3 position sentences at 25 Hz.
  /// Rate must count navigation epochs, not every sentence.
  int _epochKey(GpsFix fix) {
    // Bucket to 20 ms so same-epoch sentences with tiny time skew still merge.
    return fix.timestamp.millisecondsSinceEpoch ~/ 20;
  }

  void _listenSource(Stream<GpsFix> stream) {
    _sourceSub?.cancel();
    _sourceSub = stream.listen((fix) {
      final now = DateTime.now();
      _lastFixAt = now;
      if (fix.satellites != null) _satellites = fix.satellites;
      if (fix.accuracyM != null) _accuracyM = fix.accuracyM;

      final key = _epochKey(fix);
      if (_lastEpochKey != key) {
        _lastEpochKey = key;
        _epochReceiveTimes.add(now);
      }

      if (!_fixesController.isClosed) {
        _fixesController.add(fix);
      }
    });
  }

  void _publishQuality() {
    final now = DateTime.now();
    _epochReceiveTimes
        .removeWhere((t) => now.difference(t) > const Duration(seconds: 2));
    final nextHz = _epochReceiveTimes.isEmpty
        ? 0.0
        : (_epochReceiveTimes.length / 2.0 * 10).round() / 10.0;

    String? nextHint;
    final fresh = _lastFixAt != null &&
        now.difference(_lastFixAt!) <= const Duration(seconds: 2);
    if (!fresh) {
      final src = _usb;
      if (_active == GpsActiveSource.usb && src != null) {
        if (_lastFixAt != null) {
          nextHint = 'No recent fixes';
        } else if (src.bytesReceived <= 0) {
          nextHint = 'No serial data — close GPS Connector if stuck';
        } else if (src.nmeaLines <= 0) {
          nextHint = 'Receiving bytes, waiting for NMEA';
        } else if (src.fixCount <= 0) {
          nextHint = src.lastRejectReason ??
              'NMEA received, waiting for satellite lock';
        } else {
          nextHint = 'Waiting for fix…';
        }
      } else if (_active == GpsActiveSource.device) {
        nextHint = _lastFixAt == null
            ? 'Waiting for device GPS fix…'
            : 'No recent fixes';
      } else if (_active == GpsActiveSource.none) {
        nextHint = _lastError ?? 'No GPS source';
      }
    }

    final nextAcc = _accuracyM == null
        ? null
        : (_accuracyM! * 10).round() / 10.0;
    if (nextHz == _publishedHz &&
        _satellites == _publishedSats &&
        nextAcc == _publishedAcc &&
        nextHint == _publishedHint) {
      return;
    }

    _fixHz = nextHz;
    if (nextAcc != null) _accuracyM = nextAcc;
    _connectionHint = nextHint;
    _publishedHz = nextHz;
    _publishedSats = _satellites;
    _publishedAcc = nextAcc;
    _publishedHint = nextHint;
    notifyListeners();
  }

  Future<void> _stopActiveSource() async {
    _qualityTimer?.cancel();
    _qualityTimer = null;
    await _sourceSub?.cancel();
    _sourceSub = null;
    if (_usb != null) {
      _usb!.onDiag = null;
      await _usb!.stop();
    }
    _usb = null;
    await _device.stop();
    _resetQuality();
  }

  @override
  void dispose() {
    unawaited(_tearDown());
    super.dispose();
  }

  Future<void> _tearDown() async {
    _started = false;
    _qualityTimer?.cancel();
    _qualityTimer = null;
    _usbDebounce?.cancel();
    _usbDebounce = null;
    await _usbEventSub?.cancel();
    _usbEventSub = null;
    await _stopActiveSource();
    await _device.dispose();
    await _usb?.dispose();
    await _fixesController.close();
  }
}
