import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import '../../models/gps_fix.dart';
import 'gps_source.dart';
import 'nmea_parser.dart';

class UsbDeviceInfo {
  const UsbDeviceInfo({
    required this.deviceId,
    required this.deviceName,
    this.productName,
    this.manufacturerName,
    this.vid,
    this.pid,
  });

  final int deviceId;
  final String deviceName;
  final String? productName;
  final String? manufacturerName;
  final int? vid;
  final int? pid;

  String get displayName {
    final name = productName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final mfg = manufacturerName?.trim();
    if (mfg != null && mfg.isNotEmpty) return mfg;
    if (vid != null && pid != null) {
      return 'USB ${vid!.toRadixString(16)}:${pid!.toRadixString(16)}';
    }
    return deviceName;
  }

  String get vidPidLabel {
    if (vid == null || pid == null) return 'unknown';
    return '${vid!.toRadixString(16).padLeft(4, '0')}:'
        '${pid!.toRadixString(16).padLeft(4, '0')}';
  }

  /// Stable identity across replugs (Android deviceId is not).
  String? get stableKey {
    if (vid == null || pid == null) return null;
    return '$vid:$pid';
  }

  static UsbDeviceInfo fromUsb(UsbDevice d) => UsbDeviceInfo(
        deviceId: d.deviceId ?? 0,
        deviceName: d.deviceName,
        productName: d.productName,
        manufacturerName: d.manufacturerName,
        vid: d.vid,
        pid: d.pid,
      );
}

/// Reads NMEA over an Android USB-serial adapter (e.g. Quescan M9).
class UsbSerialGpsSource implements GpsSource {
  UsbSerialGpsSource({this.baudRate = 115200});

  int baudRate;

  final NmeaParser _parser = NmeaParser();
  final List<int> _buf = <int>[];
  StreamController<GpsFix>? _controller;
  UsbPort? _port;
  StreamSubscription<Uint8List>? _byteSub;
  String? _connectedLabel;

  int bytesReceived = 0;
  int nmeaLines = 0;
  int fixCount = 0;
  String? lastNmea;
  String? lastPositionNmea;
  String? lastRejectReason;
  String? lastOpenError;
  String? openedDriverType;
  String? connectedVidPid;
  String? rawSample;
  DateTime? lastByteAt;
  DateTime? lastNmeaAt;

  void Function()? onDiag;

  @override
  String get label => _connectedLabel ?? 'USB serial';

  @override
  Stream<GpsFix> get fixes {
    _controller ??= StreamController<GpsFix>.broadcast();
    return _controller!.stream;
  }

  static bool get isPlatformSupported => io.Platform.isAndroid;

  static const List<String> _driverTypes = <String>[
    '', // auto-detect first
    UsbSerial.CDC,
    UsbSerial.CH34x,
    UsbSerial.CP210x,
    UsbSerial.FTDI,
    UsbSerial.PL2303,
  ];

  static Future<List<UsbDeviceInfo>> listDevices() async {
    if (!isPlatformSupported) return const [];
    try {
      final devices = await UsbSerial.listDevices();
      return devices
          .where((d) => d.deviceId != null)
          .map(UsbDeviceInfo.fromUsb)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static StreamSubscription<UsbEvent>? listenUsbEvents(
    void Function(UsbEvent event) onEvent,
  ) {
    if (!isPlatformSupported) return null;
    final stream = UsbSerial.usbEventStream;
    if (stream == null) return null;
    return stream.listen(onEvent);
  }

  @override
  Future<void> start() async {
    await stop();
    if (!isPlatformSupported) {
      throw StateError('USB serial GPS is only supported on Android');
    }

    _controller ??= StreamController<GpsFix>.broadcast();
    bytesReceived = 0;
    nmeaLines = 0;
    fixCount = 0;
    lastNmea = null;
    lastPositionNmea = null;
    lastRejectReason = null;
    lastOpenError = null;
    openedDriverType = null;
    connectedVidPid = null;
    rawSample = null;
    lastByteAt = null;
    lastNmeaAt = null;
    _buf.clear();
    _parser.reset();

    final devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      throw StateError('No USB serial GPS connected');
    }

    final device = devices.first;
    final info = UsbDeviceInfo.fromUsb(device);
    connectedVidPid = info.vidPidLabel;

    final opened = await _openPort(device);
    if (opened == null) {
      final detail = lastOpenError ?? 'permission denied or port in use';
      throw StateError(
        'Failed to open USB GPS ($detail). '
        'Close GPS Connector / other serial apps, unplug/replug, then Reconnect.',
      );
    }

    final port = opened.port;
    openedDriverType = opened.driverType;

    await port.setDTR(true);
    await port.setRTS(true);
    await port.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    _port = port;
    _connectedLabel = info.displayName;

    final input = port.inputStream;
    if (input == null) {
      await stop();
      throw StateError('USB GPS input stream unavailable');
    }

    _byteSub = input.listen(
      _onBytes,
      onError: (Object e) {
        lastRejectReason = 'USB stream error: $e';
        onDiag?.call();
      },
      cancelOnError: false,
    );
  }

  Future<({UsbPort port, String driverType})?> _openPort(UsbDevice device) async {
    final errors = <String>[];
    for (final type in _driverTypes) {
      try {
        final port = await device.create(type);
        if (port == null) {
          errors.add('${type.isEmpty ? 'auto' : type}: null');
          continue;
        }
        final opened = await port.open();
        if (opened) {
          return (port: port, driverType: type.isEmpty ? 'auto' : type);
        }
        errors.add('${type.isEmpty ? 'auto' : type}: open=false');
        try {
          await port.close();
        } catch (_) {}
      } catch (e) {
        errors.add('${type.isEmpty ? 'auto' : type}: $e');
      }
    }
    lastOpenError = errors.isEmpty ? null : errors.take(3).join('; ');
    return null;
  }

  void _onBytes(Uint8List data) {
    if (data.isEmpty) return;
    bytesReceived += data.length;
    lastByteAt = DateTime.now();
    _buf.addAll(data);

    if (rawSample == null && bytesReceived >= 8) {
      rawSample = _asciiPreview(_buf.take(48).toList());
    }

    const maxBuf = 16384;
    if (_buf.length > maxBuf) {
      _buf.removeRange(0, _buf.length - maxBuf);
    }

    var emittedDiag = false;
    while (_drainNextSentence()) {
      emittedDiag = true;
    }

    if (emittedDiag || bytesReceived % 2048 < data.length) {
      onDiag?.call();
    }
  }

  static String _asciiPreview(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      if (b >= 0x20 && b <= 0x7E) {
        out.writeCharCode(b);
      } else if (b == 0x0A) {
        out.write(r'\n');
      } else if (b == 0x0D) {
        out.write(r'\r');
      } else {
        out.write('.');
      }
    }
    return out.toString();
  }

  /// Extract every `$...` sentence from the buffer (25 Hz modules often pack
  /// multiple sentences per USB chunk, sometimes without `\n` between them).
  bool _drainNextSentence() {
    final start = _buf.indexOf(0x24); // $
    if (start < 0) {
      _buf.clear();
      return false;
    }
    if (start > 0) _buf.removeRange(0, start);

    var end = -1;
    for (var i = 1; i < _buf.length; i++) {
      final b = _buf[i];
      if (b == 0x24) {
        end = i;
        break;
      }
      if (b == 0x0A || b == 0x0D) {
        end = i;
        break;
      }
    }
    if (end < 0) return false;

    final body = ascii
        .decode(_buf.sublist(1, end), allowInvalid: true)
        .trim();
    final endedAtDollar = _buf[end] == 0x24;

    if (endedAtDollar) {
      _buf.removeRange(0, end);
    } else {
      var removeEnd = end;
      while (removeEnd + 1 < _buf.length &&
          (_buf[removeEnd + 1] == 0x0D || _buf[removeEnd + 1] == 0x0A)) {
        removeEnd++;
      }
      _buf.removeRange(0, removeEnd + 1);
    }

    if (body.isEmpty) return true;
    _processSentence('\$$body');
    return true;
  }

  void _processSentence(String line) {
    nmeaLines++;
    lastNmea = line.length > 96 ? '${line.substring(0, 96)}…' : line;
    lastNmeaAt = DateTime.now();

    final isPosition = _isPositionSentence(line);
    if (isPosition) {
      lastPositionNmea = lastNmea;
    }

    final result = _parser.addLineDetailed(line);
    if (result.fix != null) {
      fixCount++;
      lastRejectReason = null;
      final c = _controller;
      if (c != null && !c.isClosed) c.add(result.fix!);
    } else if (!result.isNoise) {
      lastRejectReason = result.rejectReason;
    }
  }

  static bool _isPositionSentence(String line) {
    final u = line.toUpperCase();
    return u.contains('RMC') || u.contains('GGA') || u.contains('GLL');
  }

  @override
  Future<void> stop() async {
    await _byteSub?.cancel();
    _byteSub = null;
    _buf.clear();
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;
    _connectedLabel = null;
    onDiag = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller?.close();
    _controller = null;
  }
}
