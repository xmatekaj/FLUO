/// Service for reading and writing Apator .inp profile files.
///
/// .inp files use Protocol Buffers v2 binary encoding.
/// This is a hand-written parser to avoid protoc/build_runner dependency.
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../models/apator_profile.dart';

/// Built-in profile assets bundled with the app.
const List<({String asset, String label})> kBuiltinProfiles = [
  (asset: 'assets/js1.6_at16.inp', label: 'JS 1.6 AT-WMBUS-16'),
  (asset: 'assets/js1.6_at16_r160.inp', label: 'JS 1.6 AT-WMBUS-16 R160'),
  (asset: 'assets/js2.5_at16.inp', label: 'JS 2.5 AT-WMBUS-16'),
  (asset: 'assets/js2.5_at16_r160.inp', label: 'JS 2.5 AT-WMBUS-16 R160'),
  (asset: 'assets/js4_at16.inp', label: 'JS 4.0 AT-WMBUS-16'),
  (asset: 'assets/js4_at16_r160.inp', label: 'JS 4.0 AT-WMBUS-16 R160'),
  (asset: 'assets/smart_1-6_sm_at08.inp', label: 'Smart 1.6 AT-WMBUS-08'),
  (asset: 'assets/smart_2-5_sm_at08.inp', label: 'Smart 2.5 AT-WMBUS-08'),
  (asset: 'assets/smart_4-0_sm_at08.inp', label: 'Smart 4.0 AT-WMBUS-08'),
];

// ──────────────────────────────────────────────────────────────────────────────
// Low-level protobuf wire format helpers
// ──────────────────────────────────────────────────────────────────────────────

class _ProtobufReader {
  final Uint8List _data;
  int _pos = 0;

  _ProtobufReader(this._data);

  bool get hasMore => _pos < _data.length;
  int get position => _pos;

  /// Read a varint (up to 64-bit, returned as int).
  int readVarint() {
    int result = 0;
    int shift = 0;
    while (_pos < _data.length) {
      final byte = _data[_pos++];
      result |= (byte & 0x7F) << shift;
      if ((byte & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }

  /// Read a fixed 64-bit value (little-endian) as double.
  double readFixed64AsDouble() {
    final bd = ByteData.sublistView(_data, _pos, _pos + 8);
    _pos += 8;
    return bd.getFloat64(0, Endian.little);
  }

  /// Read length-delimited bytes.
  Uint8List readBytes() {
    final len = readVarint();
    final bytes = Uint8List.sublistView(_data, _pos, _pos + len);
    _pos += len;
    return bytes;
  }

  /// Read length-delimited string (UTF-8).
  String readString() => String.fromCharCodes(readBytes());

  /// Skip a field based on wire type.
  void skipField(int wireType) {
    switch (wireType) {
      case 0: // varint
        readVarint();
      case 1: // fixed 64-bit
        _pos += 8;
      case 2: // length-delimited
        readBytes();
      case 5: // fixed 32-bit
        _pos += 4;
    }
  }
}

class _ProtobufWriter {
  final _bytes = BytesBuilder();

  Uint8List toBytes() => _bytes.toBytes();

  void writeVarint(int value) {
    // Handle negative values (two's complement for 64-bit)
    var v = value & 0xFFFFFFFFFFFFFFFF;
    while (v > 0x7F) {
      _bytes.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _bytes.addByte(v & 0x7F);
  }

  void writeTag(int fieldNumber, int wireType) {
    writeVarint((fieldNumber << 3) | wireType);
  }

  void writeString(int field, String value) {
    writeTag(field, 2);
    final encoded = Uint8List.fromList(value.codeUnits);
    writeVarint(encoded.length);
    _bytes.add(encoded);
  }

  void writeInt32(int field, int value) {
    writeTag(field, 0);
    writeVarint(value);
  }

  void writeDouble(int field, double value) {
    writeTag(field, 1); // wire type 1 = fixed 64-bit
    final bd = ByteData(8)..setFloat64(0, value, Endian.little);
    _bytes.add(bd.buffer.asUint8List());
  }

  void writeBytes(int field, Uint8List data) {
    writeTag(field, 2);
    writeVarint(data.length);
    _bytes.add(data);
  }

  void writeNestedMessage(int field, Uint8List messageBytes) {
    writeTag(field, 2);
    writeVarint(messageBytes.length);
    _bytes.add(messageBytes);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Profile parsing / serialization
// ──────────────────────────────────────────────────────────────────────────────

/// Parse a single Parameter message from bytes.
ProfileParameter _parseParameter(Uint8List data) {
  final reader = _ProtobufReader(data);
  int register = 0;
  Uint8List paramBytes = Uint8List(0);

  while (reader.hasMore) {
    final tag = reader.readVarint();
    final fieldNumber = tag >> 3;
    final wireType = tag & 0x07;

    switch (fieldNumber) {
      case 1: // register (uint32, varint)
        register = reader.readVarint();
        // Inkasoid stores high registers as large uint32 (e.g. 0xFFFFFFA0 = -96 signed).
        // Normalize to 0x00–0xFF range.
        register = register & 0xFF;
      case 2: // parameter_bytes (bytes)
        paramBytes = Uint8List.fromList(reader.readBytes());
      default:
        reader.skipField(wireType);
    }
  }

  return ProfileParameter(register: register, bytes: paramBytes);
}

/// Serialize a Parameter to protobuf bytes.
Uint8List _serializeParameter(ProfileParameter param) {
  final w = _ProtobufWriter();
  // Store register as Inkasoid does: high registers as large uint32
  final regValue = param.register >= 0x80
      ? (param.register | 0xFFFFFF00) & 0xFFFFFFFF
      : param.register;
  w.writeInt32(1, regValue);
  w.writeBytes(2, param.bytes);
  return w.toBytes();
}

class ProfileService {
  /// Parse an .inp file from raw bytes.
  static ApatorProfile parseBytes(Uint8List data) {
    final reader = _ProtobufReader(data);
    final profile = ApatorProfile();

    while (reader.hasMore) {
      final tag = reader.readVarint();
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x07;

      switch (fieldNumber) {
        case 1: // name
          profile.name = reader.readString();
        case 2: // device_type
          profile.deviceType = reader.readString();
        case 3: // hardware_version
          profile.hardwareVersion = reader.readVarint();
        case 4: // profile_version
          profile.profileVersion = reader.readVarint();
        case 5: // timeout
          profile.timeout = reader.readVarint();
        case 6: // old_pin
          profile.oldPin = reader.readVarint();
        case 7: // new_pin
          profile.newPin = reader.readVarint();
        case 8: // capacity (double, fixed64)
          profile.capacity = reader.readFixed64AsDouble();
        case 9: // manufacturing_number
          profile.manufacturingNumber = reader.readVarint();
        case 10: // date
          profile.date = reader.readVarint();
        case 11: // parameters (repeated, length-delimited)
          final paramData = reader.readBytes();
          profile.parameters.add(_parseParameter(Uint8List.fromList(paramData)));
        default:
          reader.skipField(wireType);
      }
    }

    return profile;
  }

  /// Parse an .inp file from a file path.
  static Future<ApatorProfile> parseFile(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    return parseBytes(Uint8List.fromList(bytes));
  }

  /// Serialize a profile to protobuf bytes.
  static Uint8List serializeProfile(ApatorProfile profile) {
    final w = _ProtobufWriter();

    if (profile.name.isNotEmpty) {
      w.writeString(1, profile.name);
    }
    if (profile.deviceType.isNotEmpty) {
      w.writeString(2, profile.deviceType);
    }
    if (profile.hardwareVersion != 0) {
      w.writeInt32(3, profile.hardwareVersion);
    }
    w.writeInt32(4, profile.profileVersion);

    if (profile.timeout != 60) {
      w.writeInt32(5, profile.timeout);
    }
    if (profile.oldPin != null) {
      w.writeInt32(6, profile.oldPin!);
    }
    if (profile.newPin != null) {
      w.writeInt32(7, profile.newPin!);
    }
    if (profile.capacity != null) {
      w.writeDouble(8, profile.capacity!);
    }
    if (profile.manufacturingNumber != null) {
      w.writeInt32(9, profile.manufacturingNumber!);
    }
    if (profile.date != null) {
      w.writeInt32(10, profile.date!);
    }

    for (final param in profile.parameters) {
      final paramBytes = _serializeParameter(param);
      w.writeNestedMessage(11, paramBytes);
    }

    return w.toBytes();
  }

  /// Save a profile to an .inp file.
  static Future<void> saveFile(String path, ApatorProfile profile) async {
    final bytes = serializeProfile(profile);
    await File(path).writeAsBytes(bytes);
  }

  /// Load a profile from a bundled asset.
  static Future<ApatorProfile> loadAsset(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return parseBytes(data.buffer.asUint8List());
  }

  /// Let the user pick an .inp file and parse it.
  static Future<ApatorProfile?> pickAndParse() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );

    if (result == null || result.files.isEmpty) return null;

    final file = result.files.first;
    if (file.bytes != null) {
      return parseBytes(Uint8List.fromList(file.bytes!));
    }
    if (file.path != null) {
      return parseFile(file.path!);
    }
    return null;
  }
}
