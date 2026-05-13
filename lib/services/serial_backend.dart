// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE
//
// Abstract serial backend with platform-specific implementations:
//  - AndroidUsbBackend: uses usb_serial plugin (USB OTG, CDC-ACM/FTDI/CP210x)
//  - LinuxSerialBackend: uses flutter_libserialport (libserialport)
//
// Public API in SerialDevice / SerialBackend is platform-agnostic so that
// SerialService doesn't care which one is active.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart' as lsp;
import 'package:usb_serial/usb_serial.dart' as usbs;

/// Platform-agnostic serial device handle. Created by [SerialBackend.listDevices].
class SerialDevice {
  final String id;       // unique key (USB VID:PID or /dev/ttyACMn)
  final String label;    // human-readable
  final Object? backendData; // platform-specific (UsbDevice or device path)

  const SerialDevice({required this.id, required this.label, this.backendData});

  @override
  bool operator ==(Object other) =>
      other is SerialDevice && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// Abstract serial backend. Each platform provides one implementation.
abstract class SerialBackend {
  /// Stream of raw bytes received from the open device.
  Stream<Uint8List> get inputStream;

  /// True if a device is currently open.
  bool get isOpen;

  /// List currently visible devices. Should also fire [devicesChanged] on hotplug.
  Future<List<SerialDevice>> listDevices();

  /// Stream of device-list snapshots (called when USB hotplug detected).
  /// May be empty stream if backend doesn't support hotplug events.
  Stream<List<SerialDevice>> get devicesChanged;

  /// Open the device at given baud rate. Returns true on success.
  Future<bool> open(SerialDevice device, int baud);

  /// Close currently open device.
  Future<void> close();

  /// Write raw bytes to the open device.
  Future<bool> writeBytes(Uint8List data);

  /// Set DTR/RTS lines (used after open by some adapters).
  Future<void> setControlLines({bool dtr = true, bool rts = true});
}

/// Returns the appropriate backend for the running platform.
SerialBackend createSerialBackend() {
  if (Platform.isAndroid) {
    return AndroidUsbBackend();
  } else if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    return LinuxSerialBackend();
  }
  throw UnsupportedError('No serial backend for ${Platform.operatingSystem}');
}

// ─── Android (usb_serial) ────────────────────────────────────────────────────

class AndroidUsbBackend implements SerialBackend {
  usbs.UsbPort? _port;
  StreamSubscription<Uint8List>? _portSub;
  final _inputCtrl = StreamController<Uint8List>.broadcast();
  final _devicesCtrl = StreamController<List<SerialDevice>>.broadcast();
  StreamSubscription? _eventSub;

  @override
  Stream<Uint8List> get inputStream => _inputCtrl.stream;

  @override
  Stream<List<SerialDevice>> get devicesChanged => _devicesCtrl.stream;

  @override
  bool get isOpen => _port != null;

  void startMonitoring() {
    _eventSub ??= usbs.UsbSerial.usbEventStream?.listen((_) async {
      _devicesCtrl.add(await listDevices());
    });
  }

  @override
  Future<List<SerialDevice>> listDevices() async {
    final devs = await usbs.UsbSerial.listDevices();
    return devs.map((d) {
      final vid = d.vid?.toRadixString(16).toUpperCase().padLeft(4, '0') ?? '????';
      final pid = d.pid?.toRadixString(16).toUpperCase().padLeft(4, '0') ?? '????';
      final id  = '$vid:$pid:${d.deviceId ?? ''}';
      final label = '${d.manufacturerName ?? ''} ${d.productName ?? ''} ($vid:$pid)'.trim();
      return SerialDevice(id: id, label: label, backendData: d);
    }).toList();
  }

  @override
  Future<bool> open(SerialDevice device, int baud) async {
    await close();
    final usbDev = device.backendData as usbs.UsbDevice;
    final port = await usbDev.create(usbs.UsbSerial.CDC);
    if (port == null) return false;
    if (!await port.open()) return false;
    await port.setDTR(true);
    await port.setRTS(true);
    await port.setPortParameters(
      baud,
      usbs.UsbPort.DATABITS_8,
      usbs.UsbPort.STOPBITS_1,
      usbs.UsbPort.PARITY_NONE,
    );
    _port = port;
    _portSub = port.inputStream?.listen(_inputCtrl.add);
    return true;
  }

  @override
  Future<void> close() async {
    await _portSub?.cancel();
    _portSub = null;
    try { await _port?.close(); } catch (_) {}
    _port = null;
  }

  @override
  Future<bool> writeBytes(Uint8List data) async {
    if (_port == null) return false;
    try {
      await _port!.write(data);
      return true;
    } catch (_) { return false; }
  }

  @override
  Future<void> setControlLines({bool dtr = true, bool rts = true}) async {
    await _port?.setDTR(dtr);
    await _port?.setRTS(rts);
  }
}

// ─── Linux/macOS/Windows (flutter_libserialport) ─────────────────────────────

class LinuxSerialBackend implements SerialBackend {
  lsp.SerialPort? _port;
  lsp.SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _readerSub;
  final _inputCtrl = StreamController<Uint8List>.broadcast();
  final _devicesCtrl = StreamController<List<SerialDevice>>.broadcast();
  Timer? _hotplugTimer;
  Set<String> _lastDevList = const {};

  @override
  Stream<Uint8List> get inputStream => _inputCtrl.stream;

  @override
  Stream<List<SerialDevice>> get devicesChanged => _devicesCtrl.stream;

  @override
  bool get isOpen => _port != null && (_port?.isOpen ?? false);

  /// Poll for USB hotplug every 1.5s (libserialport doesn't expose events).
  void startMonitoring() {
    _hotplugTimer ??= Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      final list = await listDevices();
      final ids = list.map((d) => d.id).toSet();
      if (ids.length != _lastDevList.length || !ids.containsAll(_lastDevList)) {
        _lastDevList = ids;
        _devicesCtrl.add(list);
      }
    });
  }

  @override
  Future<List<SerialDevice>> listDevices() async {
    final result = <SerialDevice>[];
    for (final name in lsp.SerialPort.availablePorts) {
      try {
        final p = lsp.SerialPort(name);
        final manuf = p.manufacturer ?? '';
        final prod  = p.productName ?? '';
        final vid = p.vendorId?.toRadixString(16).toUpperCase().padLeft(4, '0') ?? '????';
        final pid = p.productId?.toRadixString(16).toUpperCase().padLeft(4, '0') ?? '????';
        final label = '$manuf $prod ($vid:$pid) $name'.replaceAll(RegExp(r'\s+'), ' ').trim();
        result.add(SerialDevice(id: name, label: label, backendData: name));
        // Don't dispose — flutter_libserialport caches per name
      } catch (_) {
        result.add(SerialDevice(id: name, label: name, backendData: name));
      }
    }
    return result;
  }

  @override
  Future<bool> open(SerialDevice device, int baud) async {
    await close();
    try {
      final port = lsp.SerialPort(device.backendData as String);
      if (!port.openReadWrite()) return false;
      // Configure on the port's own config (avoid creating a separate config
      // object — its disposal collides with port.config getter/setter and
      // produces `free(): invalid pointer` later).
      final cfg = port.config;
      cfg.baudRate = baud;
      cfg.bits = 8;
      cfg.stopBits = 1;
      cfg.parity = lsp.SerialPortParity.none;
      cfg.xonXoff = lsp.SerialPortXonXoff.disabled;
      cfg.rts = lsp.SerialPortRts.on;
      cfg.dtr = lsp.SerialPortDtr.on;
      cfg.setFlowControl(lsp.SerialPortFlowControl.none);
      port.config = cfg;
      // NOTE: do NOT dispose cfg here — port.config setter copies in but the
      // libserialport native struct is shared.
      _port = port;
      _reader = lsp.SerialPortReader(port, timeout: 100);
      _readerSub = _reader!.stream.listen(_inputCtrl.add);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    // Stop reader stream first
    await _readerSub?.cancel();
    _readerSub = null;
    try { _reader?.close(); } catch (_) {}
    _reader = null;
    // Give native side a moment to release the file descriptor
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      if (_port?.isOpen ?? false) _port?.close();
    } catch (_) {}
    // dispose() can crash on some libserialport builds; skip it — close() is enough
    _port = null;
  }

  @override
  Future<bool> writeBytes(Uint8List data) async {
    if (_port == null || !(_port?.isOpen ?? false)) return false;
    try {
      _port!.write(data, timeout: 1000);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setControlLines({bool dtr = true, bool rts = true}) async {
    if (_port == null) return;
    try {
      final cfg = _port!.config;
      cfg.dtr = dtr ? lsp.SerialPortDtr.on : lsp.SerialPortDtr.off;
      cfg.rts = rts ? lsp.SerialPortRts.on : lsp.SerialPortRts.off;
      _port!.config = cfg;
    } catch (_) {}
  }
}
