// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE
//
// Bluetooth Classic (RFCOMM) communication with Apator water meter modules.
// Protocol reverse-engineered from Inkasoid Android app.

import 'dart:async';
import 'dart:typed_data';

import '../models/apator_profile.dart' show registerById;

// ──────────────────────────────────────────────────────────────────────────────
// Apator BT protocol constants
// ──────────────────────────────────────────────────────────────────────────────

/// Command codes sent in byte 0 of every frame.
enum BtCommand {
  listeningFinish(0x00),
  readWriteRegister(0x01),
  readWriteRegisterT2(0x02),
  programmingData(0x04),
  programmingStart(0x05),
  programmingStop(0x06),
  bluetoothStatus(0x08),
  psionGetAfcOffset(0x0D),
  psionSetAfcOffset(0x0E),
  psionSetAesKey(0x0F),
  framesListening(0x40);

  final int code;
  const BtCommand(this.code);
}

/// Operation type (byte 8 of frame).
enum OverlayCode {
  read(0x00),
  write(0x01),
  faultsReset(0x02),
  programStart(0x0A),
  program(0x0B),
  programStop(0x0C);

  final int code;
  const OverlayCode(this.code);
}

/// Error codes extracted from response overlay byte.
enum OverlayError {
  ok(0),
  wrongPin(1),
  wrongInstruction(2),
  wrongRegister(3),
  wrongDataAmount(4),
  wrongCrc(5),
  tooManyParameters(6);

  final int code;
  const OverlayError(this.code);

  static OverlayError fromCode(int code) =>
      OverlayError.values.firstWhere((e) => e.code == code, orElse: () => ok);
}

/// Bluetooth-level error from response byte 0.
enum BtError {
  ok,
  wrongSoftware,
  wrongHardware,
}

// ──────────────────────────────────────────────────────────────────────────────
// CRC-16 (Modbus / poly 0xA001)
// ──────────────────────────────────────────────────────────────────────────────

/// CRC-16 used by Apator protocol (Modbus variant, poly 0xA001, init 0xFFFF).
int crc16Apator(Uint8List data, int length) {
  int crc = 0xFFFF;
  for (int i = 0; i < length; i++) {
    crc ^= data[i] & 0xFF;
    for (int bit = 0; bit < 8; bit++) {
      if ((crc & 1) == 1) {
        crc = ((crc >> 1) ^ 0xA001) & 0xFFFF;
      } else {
        crc = (crc >> 1) & 0xFFFF;
      }
    }
  }
  return crc & 0xFFFF;
}

/// Append CRC-16 to frame (big-endian).
Uint8List appendCrc(Uint8List frame) {
  final withCrc = Uint8List(frame.length + 2);
  withCrc.setAll(0, frame);
  final crc = crc16Apator(withCrc, frame.length);
  withCrc[frame.length] = (crc >> 8) & 0xFF; // MSB
  withCrc[frame.length + 1] = crc & 0xFF; // LSB
  return withCrc;
}

/// Verify CRC-16 of a received frame (last 2 bytes = CRC).
bool verifyCrc(Uint8List frame) {
  if (frame.length < 3) return false;
  final crc = crc16Apator(frame, frame.length - 2);
  return frame[frame.length - 2] == ((crc >> 8) & 0xFF) &&
      frame[frame.length - 1] == (crc & 0xFF);
}

// ──────────────────────────────────────────────────────────────────────────────
// Frame construction
// ──────────────────────────────────────────────────────────────────────────────

/// Device identity needed to build frames.
class ApatorDevice {
  final int radioNumber; // 4-byte device ID
  final int software1;
  final int software2;
  final int hardwareVersion;

  const ApatorDevice({
    required this.radioNumber,
    this.software1 = 5,
    this.software2 = 5,
    this.hardwareVersion = 7,
  });
}

/// Build a register read/write frame with PIN authentication.
///
/// Frame layout (with PIN):
///   [0] BtCommand  [1] SW1  [2] SW2  [3] HW
///   [4..7] RadioNumber (LE)
///   [8] OverlayCode
///   [9..12] PIN (BE)
///   [13] DataLength
///   [14..14+DL-1] Data
///   [14+DL..14+DL+1] CRC16
Uint8List buildRegisterFrame({
  required ApatorDevice device,
  required OverlayCode overlay,
  required int pin,
  required Uint8List data,
  BtCommand command = BtCommand.readWriteRegister,
}) {
  final frameLen = 14 + data.length; // without CRC
  final frame = Uint8List(frameLen);

  frame[0] = command.code;
  frame[1] = device.software1;
  frame[2] = device.software2;
  frame[3] = device.hardwareVersion;
  // Radio number – little-endian
  frame[4] = device.radioNumber & 0xFF;
  frame[5] = (device.radioNumber >> 8) & 0xFF;
  frame[6] = (device.radioNumber >> 16) & 0xFF;
  frame[7] = (device.radioNumber >> 24) & 0xFF;
  frame[8] = overlay.code;
  // PIN – big-endian
  frame[9] = (pin >> 24) & 0xFF;
  frame[10] = (pin >> 16) & 0xFF;
  frame[11] = (pin >> 8) & 0xFF;
  frame[12] = pin & 0xFF;
  frame[13] = data.length;
  frame.setRange(14, 14 + data.length, data);

  return appendCrc(frame);
}

/// Build a simple command frame (no device context, e.g. FramesListening).
Uint8List buildSimpleFrame(BtCommand command) {
  final frame = Uint8List(4);
  frame[0] = command.code;
  // bytes 1–3 are reserved (0x00)
  return appendCrc(frame);
}

/// Build an AES key configuration frame.
Uint8List buildAesKeyFrame(Uint8List aesKey) {
  assert(aesKey.length == 16);
  final frame = Uint8List(20);
  frame[0] = BtCommand.psionSetAesKey.code;
  // bytes 1–3 reserved
  frame.setRange(4, 20, aesKey);
  return appendCrc(frame);
}

// ──────────────────────────────────────────────────────────────────────────────
// Response parsing
// ──────────────────────────────────────────────────────────────────────────────

/// Parsed response from the Apator module.
class ApatorResponse {
  final BtError btError;
  final int afc;
  final int rssi;
  final int radioNumber;
  final OverlayCode? overlay;
  final OverlayError overlayError;
  final Uint8List data;
  final Map<int, Uint8List> registers; // register id → raw bytes

  ApatorResponse({
    required this.btError,
    required this.afc,
    required this.rssi,
    required this.radioNumber,
    this.overlay,
    this.overlayError = OverlayError.ok,
    required this.data,
    Map<int, Uint8List>? registers,
  }) : registers = registers ?? {};

  bool get isOk => btError == BtError.ok && overlayError == OverlayError.ok;
}

/// Parse a response frame from the Apator module.
///
/// Response layout:
///   [0] BtCommand + error bits (bit5=error, bit0=hw error)
///   [1] AFC MSB   [2] AFC LSB
///   [3] RSSI
///   [4..7] RadioNumber (LE)
///   [8] OverlayCode (bits 0-3) + OverlayError (bits 4-6)
///   [9] DataLength
///   [10..] Data
///   [last 2] CRC16
ApatorResponse? parseResponse(Uint8List frame) {
  if (frame.length < 6) return null;
  if (!verifyCrc(frame)) return null;

  // Error check
  BtError btError;
  if ((frame[0] & 0x20) == 0) {
    btError = BtError.ok;
  } else {
    btError = (frame[0] & 1) == 0 ? BtError.wrongSoftware : BtError.wrongHardware;
  }

  final afc = ((frame[1] & 0xFF) << 8) | (frame[2] & 0xFF);
  final rssi = frame[3] & 0xFF;
  final radioNumber = (frame[4] & 0xFF) |
      ((frame[5] & 0xFF) << 8) |
      ((frame[6] & 0xFF) << 16) |
      ((frame[7] & 0xFF) << 24);

  OverlayCode? overlay;
  OverlayError overlayError = OverlayError.ok;
  Uint8List data = Uint8List(0);

  if (frame.length > 10) {
    final overlayByte = frame[8];
    overlay = OverlayCode.values
        .where((o) => o.code == (overlayByte & 0x0F))
        .firstOrNull;
    overlayError = OverlayError.fromCode((overlayByte >> 4) & 0x07);

    final dataLen = frame[9] & 0xFF;
    if (frame.length >= 12 + dataLen) {
      data = Uint8List.sublistView(frame, 10, 10 + dataLen);
    }
  }

  return ApatorResponse(
    btError: btError,
    afc: afc,
    rssi: rssi,
    radioNumber: radioNumber,
    overlay: overlay,
    overlayError: overlayError,
    data: data,
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// Register data parsing from read response
// ──────────────────────────────────────────────────────────────────────────────

/// Parse register values from a read response.
///
/// The response data contains register values concatenated in the same order
/// as they were requested. Each register's size is looked up from
/// [kAtWmbus16Registers]. Returns a map of register ID → raw bytes.
Map<int, Uint8List> parseRegisterData(Uint8List data, List<int> requestedIds) {
  final result = <int, Uint8List>{};
  int offset = 0;
  for (final id in requestedIds) {
    final reg = registerById(id);
    if (reg == null || reg.size == 0) continue;
    if (offset + reg.size > data.length) break;
    result[id] = Uint8List.sublistView(data, offset, offset + reg.size);
    offset += reg.size;
  }
  return result;
}

/// Format a register value for human-readable display.
String formatRegisterValue(int regId, Uint8List bytes) {
  switch (regId) {
    case 0x00: // Date, Time (4B) – BCD-like or binary
      if (bytes.length >= 4) {
        final min = bytes[0] & 0x3F;
        final hour = bytes[1] & 0x1F;
        final day = bytes[2] & 0x1F;
        final mon = bytes[3] & 0x0F;
        final year = 2000 + ((bytes[2] >> 5) | ((bytes[3] >> 4) << 3));
        return '$year-${_z(mon)}-${_z(day)} ${_z(hour)}:${_z(min)}';
      }
      return _hexStr(bytes);
    case 0x02: // Current capacity (4B LE, in units of impulse weight)
    case 0xA1: // Current capacity init
      if (bytes.length >= 4) {
        final val = _u32le(bytes);
        return '${(val / 1000).toStringAsFixed(3)} m\u00B3 ($val L)';
      }
      return _hexStr(bytes);
    case 0x01: // Days without flow
      if (bytes.length >= 4) return '${_u32le(bytes)} dni';
      return _hexStr(bytes);
    case 0x2E: // Voltage (2B LE, mV)
      if (bytes.length >= 2) {
        final mv = _u16le(bytes);
        return '${(mv / 1000).toStringAsFixed(2)} V ($mv mV)';
      }
      return _hexStr(bytes);
    case 0x30: // Temperature (2B LE, 0.1°C)
      if (bytes.length >= 2) {
        final raw = _u16le(bytes);
        return '${(raw / 10).toStringAsFixed(1)} \u00B0C';
      }
      return _hexStr(bytes);
    case 0x31: // Water meter number (4B LE)
      if (bytes.length >= 4) return '${_u32le(bytes)}';
      return _hexStr(bytes);
    case 0x33: // Battery days (2B LE)
      if (bytes.length >= 2) return '${_u16le(bytes)} dni';
      return _hexStr(bytes);
    case 0x10: // Wmbus frame period (5B)
      if (bytes.length >= 5) {
        final p1 = _u16le(bytes.sublist(0, 2));
        final p2 = _u16le(bytes.sublist(2, 4));
        final mode = bytes[4];
        return 'T1=${p1}s T2=${p2}s mode=$mode';
      }
      return _hexStr(bytes);
    case 0x17: // Failures (8B)
      return _hexStr(bytes);
    case 0x03: // Reverse capacity
      if (bytes.length >= 4) {
        final val = _u32le(bytes);
        return '${(val / 1000).toStringAsFixed(3)} m\u00B3';
      }
      return _hexStr(bytes);
    case 0x14: // Days running (2B LE)
      if (bytes.length >= 2) return '${_u16le(bytes)} dni';
      return _hexStr(bytes);
    default:
      return _hexStr(bytes);
  }
}

String _z(int v) => v.toString().padLeft(2, '0');
String _hexStr(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
int _u16le(Uint8List b) => (b[0] & 0xFF) | ((b[1] & 0xFF) << 8);
int _u32le(Uint8List b) =>
    (b[0] & 0xFF) | ((b[1] & 0xFF) << 8) | ((b[2] & 0xFF) << 16) | ((b[3] & 0xFF) << 24);

// ──────────────────────────────────────────────────────────────────────────────
// Bluetooth service (abstract – concrete implementation depends on BT plugin)
// ──────────────────────────────────────────────────────────────────────────────

/// Connection state.
enum ApatorBtState { disconnected, connecting, connected }

/// Abstract Bluetooth service for Apator module communication.
///
/// Concrete implementations should use flutter_bluetooth_serial or
/// similar package for RFCOMM socket communication.
abstract class ApatorBtService {
  /// Current connection state.
  Stream<ApatorBtState> get connectionState;

  /// Discover available Bluetooth devices.
  Future<List<({String name, String address})>> discover();

  /// Connect to a device by address (RFCOMM channel 1).
  Future<bool> connect(String address);

  /// Disconnect.
  Future<void> disconnect();

  /// Send a raw frame and wait for response.
  Future<ApatorResponse?> sendFrame(Uint8List frame, {Duration timeout = const Duration(seconds: 10)});

  // ── High-level operations ───────────────────────────────────────────────

  /// Read registers from a device.
  Future<ApatorResponse?> readRegisters({
    required ApatorDevice device,
    required int pin,
    required List<int> registerIds,
  }) {
    final data = Uint8List.fromList(registerIds.map((r) => r & 0xFF).toList());
    final frame = buildRegisterFrame(
      device: device,
      overlay: OverlayCode.read,
      pin: pin,
      data: data,
    );
    return sendFrame(frame);
  }

  /// Write registers to a device. [registerData] is the pre-built write array
  /// from the device's getArrayToWrite() equivalent.
  Future<ApatorResponse?> writeRegisters({
    required ApatorDevice device,
    required int pin,
    required Uint8List registerData,
  }) {
    final frame = buildRegisterFrame(
      device: device,
      overlay: OverlayCode.write,
      pin: pin,
      data: registerData,
    );
    return sendFrame(frame);
  }

  /// Set AES key on the module.
  Future<ApatorResponse?> setAesKey(Uint8List key) {
    return sendFrame(buildAesKeyFrame(key));
  }

  /// Start W-MBus frame listening mode.
  Future<ApatorResponse?> startListening() {
    return sendFrame(buildSimpleFrame(BtCommand.framesListening));
  }

  /// Stop W-MBus frame listening mode.
  Future<ApatorResponse?> stopListening() {
    return sendFrame(buildSimpleFrame(BtCommand.listeningFinish));
  }
}
