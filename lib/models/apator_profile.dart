/// Apator water meter configuration profile.
///
/// Represents the data stored in Inkasoid .inp files (Protocol Buffers v2).
/// Supports AT-WMBUS-16-1, AT-WMBUS-16-1 R160, and SMART AT-08 devices.
library;

import 'dart:typed_data';

// ──────────────────────────────────────────────────────────────────────────────
// Register metadata for AT-WMBUS-16-1
// ──────────────────────────────────────────────────────────────────────────────

class RegisterInfo {
  final int id;
  final String name;
  final int size; // bytes; 0 = variable / not directly R/W
  final bool writable;

  const RegisterInfo(this.id, this.name, this.size, this.writable);

  /// Unsigned register id (0–255).
  int get uid => id & 0xFF;
}

/// Full register map for AT-WMBUS-16-1 (from Inkasoid source).
/// Index in list == register number (0–based for 0x00..0x3E, then 0x70..0xB5).
const List<RegisterInfo> kAtWmbus16Registers = [
  // 0x00 – 0x16 (0–22)
  RegisterInfo(0x00, 'Date, Time', 4, false),
  RegisterInfo(0x01, 'Days without flow', 4, false),
  RegisterInfo(0x02, 'Current capacity', 4, true),
  RegisterInfo(0x03, 'Reverse capacity', 4, true),
  RegisterInfo(0x04, 'Reverse volume threshold', 1, true),
  RegisterInfo(0x05, 'Monthly capacity', 7, true),
  RegisterInfo(0x06, 'Volume history', 4, false),
  RegisterInfo(0x07, '10 sec flow', 1, false),
  RegisterInfo(0x08, 'Min threshold', 3, true),
  RegisterInfo(0x09, 'Max threshold', 2, true),
  RegisterInfo(0x0A, 'Var flow', 2, true),
  RegisterInfo(0x0B, 'Stop threshold', 1, true),
  RegisterInfo(0x0C, 'Def leakage amount', 2, true),
  RegisterInfo(0x0D, 'Cfg frame power', 2, true),
  RegisterInfo(0x0E, 'Cfg frame period', 2, true),
  RegisterInfo(0x0F, 'Wmbus frame power', 1, true),
  RegisterInfo(0x10, 'Wmbus frame period', 5, true),
  RegisterInfo(0x11, 'Wmbus frame setup', 8, true),
  RegisterInfo(0x12, 'TTL', 16, true),
  RegisterInfo(0x13, 'RSSI threshold', 8, true),
  RegisterInfo(0x14, 'Days running', 2, true),
  RegisterInfo(0x15, 'Switch-on/-off time', 16, true),
  RegisterInfo(0x16, 'Read day', 1, true),
  // 0x17 (23) – Failures (read-only)
  RegisterInfo(0x17, 'Failures', 8, false),
  // 0x18 (24) – Cfg frame period (duplicate name in Inkasoid)
  RegisterInfo(0x18, 'Cfg frame period 2', 0, false),
  // 0x19–0x2F (25–47) – event/history registers (read-only)
  RegisterInfo(0x19, 'Extr history', 0, false),
  RegisterInfo(0x1A, 'Bor amount', 0, false),
  RegisterInfo(0x1B, 'Bor history', 0, false),
  RegisterInfo(0x1C, 'Wdr amount', 0, false),
  RegisterInfo(0x1D, 'Wdr history', 0, false),
  RegisterInfo(0x1E, 'Voltage history', 0, false),
  RegisterInfo(0x1F, 'Magnet time', 0, false),
  RegisterInfo(0x20, 'Magnet history', 0, false),
  RegisterInfo(0x21, 'Lighting time', 0, false),
  RegisterInfo(0x22, 'Lighting history', 0, false),
  RegisterInfo(0x23, 'Removal time', 0, false),
  RegisterInfo(0x24, 'Removal history', 0, false),
  RegisterInfo(0x25, 'Det123 failure time', 0, false),
  RegisterInfo(0x26, 'Det123 failure history', 0, false),
  RegisterInfo(0x27, 'Reverse total', 0, false),
  RegisterInfo(0x28, 'Reverse history', 0, false),
  RegisterInfo(0x29, 'Peak flow', 0, false),
  RegisterInfo(0x2A, 'Leak failure history', 0, false),
  RegisterInfo(0x2B, 'Max plus total', 0, false),
  RegisterInfo(0x2C, 'Max minus total', 0, false),
  RegisterInfo(0x2D, 'Max history', 0, false),
  // 0x2E–0x2F (46–47) – diagnostic / info
  RegisterInfo(0x2E, 'Voltage', 2, false),
  RegisterInfo(0x2F, 'Detectors current', 6, false),
  // 0x30–0x35 (48–53) – more info / config
  RegisterInfo(0x30, 'Temperature', 2, false),
  RegisterInfo(0x31, 'Water meter number', 4, true),
  RegisterInfo(0x32, 'Access code (PIN)', 4, true),
  RegisterInfo(0x33, 'Battery days', 2, true),
  RegisterInfo(0x34, 'Osccal value', 0, false),
  RegisterInfo(0x35, 'Diag det 1/2/3', 0, false),
  // High registers (0xA0–0xB5) used in profiles
  RegisterInfo(0xA0, 'Manufacturing number', 4, true),
  RegisterInfo(0xA1, 'Current capacity (init)', 4, true),
  RegisterInfo(0xA2, 'Control byte', 1, true),
  RegisterInfo(0xA3, 'RTC date/time', 7, true),
  RegisterInfo(0xA4, 'Autoreset', 4, true),
  RegisterInfo(0xA5, 'Impulse weight', 1, true),
  RegisterInfo(0xA6, 'Thresholds 3x1B', 3, true),
  RegisterInfo(0xA7, 'Flow min/max 2x1B', 2, true),
  RegisterInfo(0xA8, 'Stop/leak 2x1B', 2, true),
  RegisterInfo(0xA9, 'Leakage def', 1, true),
  RegisterInfo(0xAA, 'Cfg periods 2B', 2, true),
  RegisterInfo(0xAB, 'Reserved AB', 0, false),
  RegisterInfo(0xAC, 'Wmbus periods 2B', 2, true),
  RegisterInfo(0xAD, 'Reserved AD', 0, false),
  RegisterInfo(0xAE, 'Reserved AE', 0, false),
  RegisterInfo(0xAF, 'Reserved AF', 1, true),
  RegisterInfo(0xB0, 'Frame periods 5B', 5, true),
  RegisterInfo(0xB1, 'Timetable 8B', 8, true),
  RegisterInfo(0xB2, 'AES key', 16, true),
  RegisterInfo(0xB3, 'Frame configuration 8B', 8, true),
  RegisterInfo(0xB4, 'Life days 2B', 2, true),
  RegisterInfo(0xB5, 'Frame configuration 16B', 16, true),
];

/// Look up register info by id. Returns null if unknown.
RegisterInfo? registerById(int id) {
  final uid = id & 0xFF;
  for (final r in kAtWmbus16Registers) {
    if (r.uid == uid) return r;
  }
  return null;
}

// ──────────────────────────────────────────────────────────────────────────────
// Profile model
// ──────────────────────────────────────────────────────────────────────────────

/// A single register value stored in a profile.
class ProfileParameter {
  /// Register number (stored as uint32 in protobuf, but Apator uses byte range).
  final int register;

  /// Raw bytes to write to the register.
  final Uint8List bytes;

  ProfileParameter({required this.register, required this.bytes});

  /// Human-readable register name.
  String get name => registerById(register)?.name ?? 'Register 0x${register.toRadixString(16).toUpperCase()}';

  /// Is this register writable?
  bool get writable => registerById(register)?.writable ?? false;

  /// Display hex representation of bytes.
  String get hexValue => bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  @override
  String toString() => '$name (0x${register.toRadixString(16)}): $hexValue';
}

/// Apator device profile – maps to the protobuf Profile message in .inp files.
class ApatorProfile {
  String name;
  String deviceType;
  int hardwareVersion;
  int profileVersion;
  int timeout;
  int? oldPin;
  int? newPin;
  double? capacity;
  int? manufacturingNumber;
  int? date;
  List<ProfileParameter> parameters;

  ApatorProfile({
    this.name = '',
    this.deviceType = '',
    this.hardwareVersion = 0,
    this.profileVersion = 1,
    this.timeout = 60,
    this.oldPin,
    this.newPin,
    this.capacity,
    this.manufacturingNumber,
    this.date,
    List<ProfileParameter>? parameters,
  }) : parameters = parameters ?? [];

  /// Writable parameters only (for sending to device).
  List<ProfileParameter> get writableParameters =>
      parameters.where((p) => p.writable).toList();

  @override
  String toString() =>
      'ApatorProfile($name, $deviceType, hw=$hardwareVersion, '
      'params=${parameters.length})';
}
