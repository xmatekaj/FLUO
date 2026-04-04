// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE

import 'dart:async';
import 'dart:typed_data';
import 'package:usb_serial/usb_serial.dart';
import 'wmbus_decoder.dart';

enum SerialState { disconnected, connected }

class SerialDevice {
  final UsbDevice usbDevice;
  SerialDevice(this.usbDevice);

  String get label =>
      '${usbDevice.manufacturerName ?? ''} ${usbDevice.productName ?? ''} '
      '(${usbDevice.vid?.toRadixString(16).toUpperCase()}:'
      '${usbDevice.pid?.toRadixString(16).toUpperCase()})'
          .trim();
}

class SerialService {
  SerialService._();
  static final SerialService instance = SerialService._();

  UsbPort? _port;
  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<UsbEvent>? _eventSub;
  final _buf = <int>[];

  SerialState _state = SerialState.disconnected;
  SerialState get state => _state;

  final _frameController   = StreamController<Uint8List>.broadcast();
  final _errorController   = StreamController<String>.broadcast();
  final _stateController   = StreamController<SerialState>.broadcast();
  final _deviceController  = StreamController<List<SerialDevice>>.broadcast();

  Stream<Uint8List>        get frames  => _frameController.stream;
  Stream<String>           get errors  => _errorController.stream;
  Stream<SerialState>      get states  => _stateController.stream;
  Stream<List<SerialDevice>> get devices => _deviceController.stream;

  /// Start listening for USB attach/detach events.
  void startMonitoring() {
    _eventSub ??= UsbSerial.usbEventStream?.listen((event) async {
      await refreshDevices();
    });
  }

  Future<List<SerialDevice>> refreshDevices() async {
    final devs = await UsbSerial.listDevices();
    final list = devs.map((d) => SerialDevice(d)).toList();
    _deviceController.add(list);
    return list;
  }

  Future<void> connect(SerialDevice dev, int baud) async {
    await disconnect();
    final port = await dev.usbDevice.create(UsbSerial.CDC);
    if (port == null) {
      _errorController.add('Cannot open USB port for ${dev.label}');
      return;
    }
    if (!await port.open()) {
      _errorController.add('Failed to open port for ${dev.label}');
      return;
    }
    await port.setDTR(true);
    await port.setRTS(true);
    await port.setPortParameters(
      baud,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    _port = port;
    _state = SerialState.connected;
    _stateController.add(_state);
    _buf.clear();

    _dataSub = port.inputStream?.listen(
      (data) {
        _buf.addAll(data);
        for (final frame in extractFrames(_buf)) {
          _frameController.add(frame);
        }
      },
      onError: (e) {
        _errorController.add('Read error: $e');
        disconnect();
      },
      onDone: () {
        _state = SerialState.disconnected;
        _stateController.add(_state);
      },
    );
  }

  Future<void> disconnect() async {
    await _dataSub?.cancel();
    _dataSub = null;
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;
    _state = SerialState.disconnected;
    _stateController.add(_state);
  }

  void dispose() {
    _dataSub?.cancel();
    _eventSub?.cancel();
    _port?.close();
    _frameController.close();
    _errorController.close();
    _stateController.close();
    _deviceController.close();
  }
}
