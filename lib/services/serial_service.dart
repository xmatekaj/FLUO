// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE
//
// SerialService — platform-agnostic facade. Uses SerialBackend (Android USB
// or Linux libserialport). Holds Adeunis ARF8020AA command-mode protocol logic.

import 'dart:async';
import 'dart:typed_data';

import 'serial_backend.dart';
import 'wmbus_decoder.dart';

export 'serial_backend.dart' show SerialDevice;

enum SerialState { disconnected, connected }

/// Adeunis ARF8020AA radio modes — values for `M` command.
/// Per ARF8020AA User Guide V1.4.2 (mode select table):
///   T (0x54) = T1, t (0x74) = T2, S (0x53) = S1m, L (0x4C) = S1,
///   s (0x73) = S2, R (0x52) = R one-way, r (0x72) = R
enum AdeunisLinkMode {
  t1('T', 'T1'),
  t2('t', 'T2'),
  s1m('S', 'S1m'),
  s1('L', 'S1'),
  s2('s', 'S2'),
  rOneWay('R', 'R1way'),
  r('r', 'R');
  final String char;
  final String label;
  const AdeunisLinkMode(this.char, this.label);
}

/// Adeunis ARF8020AA roles — values for `L` command.
enum AdeunisRole {
  meter('M', 'Meter'),
  other('O', 'Other');
  final String char;
  final String label;
  const AdeunisRole(this.char, this.label);
}

class SerialService {
  SerialService._();
  static final SerialService instance = SerialService._();

  final SerialBackend _backend = createSerialBackend();
  StreamSubscription<Uint8List>? _dataSub;
  StreamSubscription<List<SerialDevice>>? _hotplugSub;
  final _buf = <int>[];

  SerialState _state = SerialState.disconnected;
  SerialState get state => _state;

  final _frameController   = StreamController<Uint8List>.broadcast();
  final _errorController   = StreamController<String>.broadcast();
  final _stateController   = StreamController<SerialState>.broadcast();
  final _deviceController  = StreamController<List<SerialDevice>>.broadcast();
  final _rawController     = StreamController<Uint8List>.broadcast();

  Stream<Uint8List>          get frames   => _frameController.stream;
  Stream<String>             get errors   => _errorController.stream;
  Stream<SerialState>        get states   => _stateController.stream;
  Stream<List<SerialDevice>> get devices  => _deviceController.stream;
  Stream<Uint8List>          get rawBytes => _rawController.stream;

  /// Start monitoring USB hotplug (calls refreshDevices on attach/detach).
  void startMonitoring() {
    if (_backend is AndroidUsbBackend) {
      (_backend as AndroidUsbBackend).startMonitoring();
    } else if (_backend is LinuxSerialBackend) {
      (_backend as LinuxSerialBackend).startMonitoring();
    }
    _hotplugSub ??= _backend.devicesChanged.listen((list) {
      _deviceController.add(list);
    });
  }

  Future<List<SerialDevice>> refreshDevices() async {
    final list = await _backend.listDevices();
    _deviceController.add(list);
    return list;
  }

  Future<void> connect(SerialDevice dev, int baud) async {
    await disconnect();
    final ok = await _backend.open(dev, baud);
    if (!ok) {
      _errorController.add('Cannot open ${dev.label}');
      return;
    }
    _state = SerialState.connected;
    _stateController.add(_state);
    _buf.clear();

    _dataSub = _backend.inputStream.listen(
      (data) {
        _rawController.add(data);
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

  // ── Adeunis ARF8020AA protocol ──────────────────────────────────────────
  // Wejście w command mode: FF×8 FD '+' '+' '+' → '>' (OK) or '#' (err)
  // Set: 2-byte interactive `<KEY><VALUE>` uppercase (e.g. Mt for T2, LO for Other)
  // Exit: Z (Quit). Save NV: S.
  static final Uint8List _kEnterCmdMode = Uint8List.fromList([
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFD, 0x2B, 0x2B, 0x2B,
  ]);

  Future<bool> _writeBytes(Uint8List data) async {
    if (_state != SerialState.connected) return false;
    final ok = await _backend.writeBytes(data);
    if (!ok) _errorController.add('write error');
    return ok;
  }

  Future<bool> _awaitAsciiChar(String expected,
      {Duration timeout = const Duration(milliseconds: 500)}) async {
    final completer = Completer<bool>();
    final target = expected.codeUnitAt(0);
    final sub = _rawController.stream.listen((data) {
      if (data.contains(target)) {
        if (!completer.isCompleted) completer.complete(true);
      }
    });
    Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    final r = await completer.future;
    await sub.cancel();
    return r;
  }

  /// Enter Adeunis command mode. Returns true if dongle replied '>' (OK).
  Future<bool> enterCommandMode() async {
    final ackFuture = _awaitAsciiChar('>', timeout: const Duration(milliseconds: 1500));
    final ok = await _writeBytes(_kEnterCmdMode);
    if (!ok) return false;
    return ackFuture;
  }

  Future<bool> sendCmdChar(String c) async {
    return _writeBytes(Uint8List.fromList(c.codeUnits));
  }

  /// 2-byte interactive set: `<KEY><VALUE>`. Both uppercase ASCII.
  Future<bool> sendKeyValue(String key, String value) async {
    final cmd = '$key$value';
    return _writeBytes(Uint8List.fromList(cmd.codeUnits));
  }

  /// Set radio mode via `M<char>`.
  Future<bool> setRadioMode(AdeunisLinkMode mode) async {
    return sendKeyValue('M', mode.char);
  }

  /// Set role via `L<char>`.
  Future<bool> setRole(AdeunisRole role) async {
    return sendKeyValue('L', role.char);
  }

  /// Quit command mode. Returns to streaming RX.
  Future<bool> exitCommandMode() async {
    return sendCmdChar('Z');
  }

  /// Save current parameters to flash. Send only at top-level prompt.
  Future<bool> saveParameters() async {
    return sendCmdChar('S');
  }

  /// Wait for `>` or `#`. Returns the char or null on timeout.
  Future<String?> _awaitAsciiChars(List<String> expected,
      {Duration timeout = const Duration(milliseconds: 500)}) async {
    final completer = Completer<String?>();
    final targets = expected.map((e) => e.codeUnitAt(0)).toSet();
    final sub = _rawController.stream.listen((data) {
      for (final b in data) {
        if (targets.contains(b)) {
          if (!completer.isCompleted) {
            completer.complete(String.fromCharCode(b));
          }
          return;
        }
      }
    });
    Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    final r = await completer.future;
    await sub.cancel();
    return r;
  }

  /// Send single char and wait for prompt '>' (or '#' on err).
  Future<bool> sendCmdCharAwaitPrompt(String c,
      {Duration timeout = const Duration(milliseconds: 300)}) async {
    final ackFuture = _awaitAsciiChars(['>', '#'], timeout: timeout);
    if (!await sendCmdChar(c)) return false;
    final r = await ackFuture;
    return r == '>';
  }

  /// Send wMBus frame in T2 RX-window using bidirectional TX framing:
  /// `FF FE [L] [C] [M(2)] [A(6)] [CI] [data]`
  Future<bool> txT2Frame(Uint8List wmbusFrameWithoutSof) async {
    if (wmbusFrameWithoutSof.isEmpty || wmbusFrameWithoutSof.length > 254) return false;
    final packet = Uint8List(2 + wmbusFrameWithoutSof.length);
    packet[0] = 0xFF;
    packet[1] = 0xFE;
    packet.setRange(2, packet.length, wmbusFrameWithoutSof);
    return _writeBytes(packet);
  }

  /// Raw byte transmission — sends bytes verbatim to dongle UART.
  /// Use to experiment with different TX framings (no prefix, FF only, etc.)
  Future<bool> txRawBytes(Uint8List bytes) async {
    if (bytes.isEmpty) return false;
    return _writeBytes(bytes);
  }

  Future<void> disconnect() async {
    await _dataSub?.cancel();
    _dataSub = null;
    await _backend.close();
    _state = SerialState.disconnected;
    _stateController.add(_state);
  }

  void dispose() {
    _dataSub?.cancel();
    _hotplugSub?.cancel();
    _backend.close();
    _frameController.close();
    _errorController.close();
    _stateController.close();
    _deviceController.close();
    _rawController.close();
  }
}
