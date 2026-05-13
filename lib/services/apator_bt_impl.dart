// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE
//
// ApatorBtService implementation using native RFCOMM channel 1
// (same approach as Inkasoid: createRfcommSocket(1) via reflection).

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'apator_bt_service.dart';
import 'wmbus_decoder.dart' show extractBtFrames;

/// Operating mode of the BT connection.
enum BtMode { idle, listening, service }

class ApatorBtServiceImpl extends ApatorBtService {
  static final ApatorBtServiceImpl instance = ApatorBtServiceImpl._();
  ApatorBtServiceImpl._();

  static const _method = MethodChannel('pl.matekaj.fluo/apator_bt');
  static const _dataChannel = EventChannel('pl.matekaj.fluo/apator_bt/data');
  static const _statusChannel = EventChannel('pl.matekaj.fluo/apator_bt/status');

  final _stateCtrl = StreamController<ApatorBtState>.broadcast();
  ApatorBtState _state = ApatorBtState.disconnected;

  StreamSubscription? _dataSub;
  StreamSubscription? _statusSub;

  final _rxBuffer = BytesBuilder();
  Completer<Uint8List>? _responseCompleter;
  Timer? _responseTimer;

  /// Current mode.
  BtMode _mode = BtMode.idle;
  BtMode get mode => _mode;

  /// Stream of wMBus frames received in listening mode.
  /// Frames are prefixed with 0xFF (SOF) so they can be passed to parseRawFrame.
  final _frameCtrl = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get wmbusFrames => _frameCtrl.stream;

  /// Buffer for BT frame reassembly (0x02..0x03 delimited).
  final _btFrameBuf = <int>[];

  /// Last error message for diagnostics.
  String? lastError;

  /// Callback for UI to get notified about new discovered devices.
  void Function(List<({String name, String address})> devices)? onDevicesUpdated;

  @override
  Stream<ApatorBtState> get connectionState => _stateCtrl.stream;
  ApatorBtState get currentState => _state;

  void _setState(ApatorBtState s) {
    _state = s;
    _stateCtrl.add(s);
  }

  Future<bool> _ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
    ].request();

    final allGranted = statuses.values.every(
      (s) => s == PermissionStatus.granted,
    );

    if (!allGranted) {
      final denied = statuses.entries
          .where((e) => e.value != PermissionStatus.granted)
          .map((e) => e.key.toString())
          .join(', ');
      lastError = 'Brak uprawnien: $denied';
    }
    return allGranted;
  }

  @override
  Future<List<({String name, String address})>> discover() async {
    if (!Platform.isAndroid) {
      lastError = 'Bluetooth dostępny tylko na Androidzie';
      return [];
    }
    final hasPerms = await _ensurePermissions();
    if (!hasPerms) return [];

    try {
      final result = await _method.invokeMethod('getPairedDevices');
      final list = (result as List).cast<Map>();
      return list
          .map((m) => (
                name: '${m["name"]} (sparowane)',
                address: m["address"] as String,
              ))
          .toList();
    } catch (e) {
      lastError = 'getPairedDevices: $e';
      return [];
    }
  }

  @override
  Future<bool> connect(String address) async {
    if (!Platform.isAndroid) {
      lastError = 'Bluetooth dostępny tylko na Androidzie';
      return false;
    }
    if (_state == ApatorBtState.connected) {
      await disconnect();
    }
    _setState(ApatorBtState.connecting);
    _mode = BtMode.idle;

    // Listen for status changes from native.
    _statusSub?.cancel();
    _statusSub = _statusChannel.receiveBroadcastStream().listen((status) {
      final s = status as int;
      if (s == 2) {
        _setState(ApatorBtState.connected);
      } else if (s == 0) {
        _setState(ApatorBtState.disconnected);
        _mode = BtMode.idle;
      }
    });

    // Listen for incoming data from native.
    _dataSub?.cancel();
    _dataSub = _dataChannel.receiveBroadcastStream().listen(_onData);

    try {
      await _method.invokeMethod('connect', {'address': address});
      _setState(ApatorBtState.connected);
      return true;
    } catch (e) {
      _setState(ApatorBtState.disconnected);
      lastError = 'connect: $e';
      return false;
    }
  }

  void _onData(dynamic data) {
    final bytes = data as Uint8List;

    if (_mode == BtMode.listening) {
      // In listening mode, feed bytes to the frame extractor.
      _btFrameBuf.addAll(bytes);
      for (final frame in extractBtFrames(_btFrameBuf)) {
        _frameCtrl.add(frame);
      }
    } else {
      // In service/idle mode, accumulate for response completer.
      _rxBuffer.add(bytes);
      _responseTimer?.cancel();
      _responseTimer = Timer(const Duration(milliseconds: 150), () {
        if (_responseCompleter != null && !_responseCompleter!.isCompleted) {
          _responseCompleter!.complete(_rxBuffer.toBytes());
          _rxBuffer.clear();
          _responseCompleter = null;
        }
      });
    }
  }

  /// Start wMBus frame listening mode.
  /// Returns true if the command was sent successfully.
  Future<bool> startListeningMode() async {
    if (_state != ApatorBtState.connected) return false;

    _btFrameBuf.clear();
    final frame = buildSimpleFrame(BtCommand.framesListening);
    try {
      await _method.invokeMethod('write', {'data': frame});
      _mode = BtMode.listening;
      return true;
    } catch (e) {
      lastError = 'startListening: $e';
      return false;
    }
  }

  /// Stop wMBus frame listening mode.
  Future<bool> stopListeningMode() async {
    if (_state != ApatorBtState.connected) return false;

    final frame = buildSimpleFrame(BtCommand.listeningFinish);
    try {
      await _method.invokeMethod('write', {'data': frame});
      _mode = BtMode.idle;
      _btFrameBuf.clear();
      return true;
    } catch (e) {
      lastError = 'stopListening: $e';
      return false;
    }
  }

  @override
  Future<void> disconnect() async {
    _responseTimer?.cancel();
    _dataSub?.cancel();
    _statusSub?.cancel();
    _mode = BtMode.idle;
    _btFrameBuf.clear();
    try {
      await _method.invokeMethod('disconnect');
    } catch (_) {}
    _setState(ApatorBtState.disconnected);
  }

  @override
  Future<ApatorResponse?> sendFrame(
    Uint8List frame, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_state != ApatorBtState.connected) return null;

    // Switch to service mode if in listening mode.
    if (_mode == BtMode.listening) {
      await stopListeningMode();
      await Future.delayed(const Duration(milliseconds: 200));
    }

    _mode = BtMode.service;
    _rxBuffer.clear();
    _responseCompleter = Completer<Uint8List>();

    try {
      await _method.invokeMethod('write', {'data': frame});
    } catch (e) {
      lastError = 'write: $e';
      _responseCompleter = null;
      _mode = BtMode.idle;
      return null;
    }

    try {
      final responseBytes = await _responseCompleter!.future.timeout(timeout);
      _mode = BtMode.idle;
      return parseResponse(responseBytes);
    } on TimeoutException {
      _responseCompleter = null;
      _mode = BtMode.idle;
      return null;
    }
  }

  void dispose() {
    disconnect();
    _stateCtrl.close();
    _frameCtrl.close();
  }
}
