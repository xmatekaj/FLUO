// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE
//
// Dart port of decode_wmbus.py – W-MBus frame parsing, AES-128-CBC
// decryption and OMS DIF/VIF payload parsing for Apator APA water meters.
// Also handles Techem MK Radio 3 (CI=0xA2, unencrypted) and
// Techem FHKV Data III (CI=0xA0, HCA, unencrypted).

import 'dart:math' as math;
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart' show debugPrint;

// ── CRC-16 (poly 0x3D65) ─────────────────────────────────────────────────────

const int _crcPoly = 0x3D65;

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (int i = 0; i < 256; i++) {
    int crc = 0, a = (i << 8) & 0xFFFF;
    for (int j = 0; j < 8; j++) {
      if ((crc ^ a) & 0x8000 != 0) {
        crc = ((crc << 1) ^ _crcPoly) & 0xFFFF;
      } else {
        crc = (crc << 1) & 0xFFFF;
      }
      a = (a << 1) & 0xFFFF;
    }
    t[i] = crc;
  }
  return t;
}();

int _crc16(Uint8List data) {
  int crc = 0;
  for (final b in data) {
    crc = (((crc & 0xFFFF) << 8) ^ _crcTable[((crc >> 8) ^ b) & 0xFF]) & 0xFFFF;
  }
  return crc;
}

bool _checkCrc(Uint8List block) {
  final c = _crc16(block.sublist(0, block.length - 2));
  return ((c >> 8) & 0xFF) == (block[block.length - 2] ^ 0xFF) &&
      (c & 0xFF) == (block[block.length - 1] ^ 0xFF);
}

// ── Frame extraction from byte stream ────────────────────────────────────────

/// Extract complete W-MBus frames from a mutable buffer.
/// Consumed bytes are removed from the front of [buf].
/// Returns list of complete raw frames.
List<Uint8List> extractFrames(List<int> buf) {
  final frames = <Uint8List>[];
  int i = 0;
  while (i < buf.length) {
    if (buf[i] != 0xFF) { i++; continue; }
    if (i + 1 >= buf.length) break;
    final L = buf[i + 1];
    final payloadLen = L - 9;
    if (payloadLen <= 0) { i++; continue; }
    final nCrc  = ((payloadLen + 15) ~/ 16);
    // Frame: SOF(1)+L(1)+C(1)+M(2)+A(6)+data(payloadLen)+dataCRCs(nCrc*2)
    // (Adeunis-RF dongle does NOT include header CRC)
    final total = 11 + payloadLen + nCrc * 2;
    if (i + total > buf.length) break;
    frames.add(Uint8List.fromList(buf.sublist(i, i + total)));
    i += total;
  }
  buf.removeRange(0, i);
  return frames;
}

// ── Parsed frame ─────────────────────────────────────────────────────────────

class ParsedFrame {
  final int lField;
  final Uint8List mBytes;   // 2 bytes
  final Uint8List aBytes;   // 6 bytes
  final int sw;
  final int hw;
  final int radioNum;
  final Uint8List blockData;
  final bool crcOk;
  ParsedFrame({
    required this.lField,
    required this.mBytes,
    required this.aBytes,
    required this.sw,
    required this.hw,
    required this.radioNum,
    required this.blockData,
    required this.crcOk,
  });
}

/// Parse raw frame bytes (SOF=0xFF prefix).
/// Frame layout from Adeunis-RF dongle (no header CRC):
///   SOF(1) + L(1) + C(1) + M(2) + A(6) + dataBlocks(payload with block CRCs)
ParsedFrame? parseRawFrame(Uint8List raw) {
  if (raw.isEmpty || raw[0] != 0xFF || raw.length < 12) return null;

  final lField    = raw[1];
  final mBytes    = raw.sublist(3, 5);
  final aBytes    = raw.sublist(5, 11);
  final idBytes   = aBytes.sublist(0, 4);
  final sw        = aBytes[4];
  final hw        = aBytes[5];

  // Radio number: reversed BCD from ID bytes
  final radioHex = '${idBytes[3].toRadixString(16).padLeft(2, '0')}'
                   '${idBytes[2].toRadixString(16).padLeft(2, '0')}'
                   '${idBytes[1].toRadixString(16).padLeft(2, '0')}'
                   '${idBytes[0].toRadixString(16).padLeft(2, '0')}';
  final int radioNum = int.tryParse(radioHex) ?? 0;

  final payloadLen = lField - 9;
  if (payloadLen <= 0) return null;
  final nBlocks = ((payloadLen + 15) ~/ 16);

  // Data blocks start at raw[11] (no header CRC from this dongle)
  final rawBlocks = raw.sublist(11);

  // Strip data-block CRCs
  final out = <int>[];
  int off = 0;
  bool crcOk = true;
  for (int i = 0; i < nBlocks; i++) {
    final blen = (i < nBlocks - 1 || payloadLen % 16 == 0) ? 16 : payloadLen % 16;
    final end = off + blen + 2;
    if (end > rawBlocks.length) {
      debugPrint('WMBUS CRC: block $i short: need $end have ${rawBlocks.length}');
      crcOk = false; break;
    }
    final blk = rawBlocks.sublist(off, end);
    final ok = _checkCrc(Uint8List.fromList(blk));
    if (!ok) {
      debugPrint('WMBUS CRC: block $i FAIL data=${blk.sublist(0,math.min(4,blen)).map((b)=>b.toRadixString(16).padLeft(2,"0")).join()} crc=${blk[blen].toRadixString(16).padLeft(2,"0")}${blk[blen+1].toRadixString(16).padLeft(2,"0")}');
      crcOk = false; break;
    }
    out.addAll(blk.sublist(0, blen));
    off += blen + 2;
  }

  final blockData = crcOk
      ? Uint8List.fromList(out)
      : rawBlocks.sublist(0, math.min(payloadLen, rawBlocks.length));

  return ParsedFrame(
    lField: lField,
    mBytes: Uint8List.fromList(mBytes),
    aBytes: Uint8List.fromList(aBytes),
    sw: sw,
    hw: hw,
    radioNum: radioNum,
    blockData: blockData,
    crcOk: crcOk,
  );
}

// ── AES-128-CBC ───────────────────────────────────────────────────────────────

Uint8List buildIv(Uint8List m, Uint8List a, int tplAcc) {
  return Uint8List.fromList([...m, ...a, ...List.filled(8, tplAcc & 0xFF)]);
}

Uint8List? decryptCbc(List<int> key, Uint8List iv, Uint8List ct) {
  if (ct.isEmpty || ct.length % 16 != 0) return null;
  try {
    final k = enc.Key(Uint8List.fromList(key));
    final i = enc.IV(iv);
    final cipher = enc.Encrypter(enc.AES(k, mode: enc.AESMode.cbc, padding: null));
    return Uint8List.fromList(
      cipher.decryptBytes(enc.Encrypted(ct), iv: i),
    );
  } catch (_) {
    return null;
  }
}

// ── OMS DIF/VIF parser ────────────────────────────────────────────────────────

// VIF → m³ multiplier (0x10–0x17) per EN 13757-3
final Map<int, double> _volVifs = {
  for (int v = 0x10; v < 0x18; v++) v: math.pow(10, (v & 0x07) - 6).toDouble(),
};

// Data size by DIF bits 3:0
const Map<int, int> _difSize = {
  0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 4, 6: 6, 7: 8,
  8: 0, 9: 1, 10: 2, 11: 3, 12: 4, 13: -1, 14: 6, 15: -2,
};

DateTime? _typeFDatetime(Uint8List b) {
  if (b.length < 4) return null;
  final min  = b[0] & 0x3F;
  final hour = b[1] & 0x1F;
  final day  = b[2] & 0x1F;
  final yrLo = (b[2] >> 5) & 0x07;
  final mon  = b[3] & 0x0F;
  final yrHi = (b[3] >> 4) & 0x07;
  final year = 2000 + (yrHi << 3 | yrLo);
  try {
    return DateTime(year, mon, day, hour, min);
  } catch (_) {
    return null;
  }
}

int _readInt32Le(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

class OmsResult {
  double? volumeM3;
  DateTime? timestamp;
  int? faultsWord;
  List<HistRaw> history = [];
}

class HistRaw { final int impulses; HistRaw(this.impulses); }

OmsResult parseOmsPayload(Uint8List payload) {
  final result = OmsResult();
  int i = 0;

  // Skip 0x2F verification bytes
  while (i < payload.length && payload[i] == 0x2F) i++;

  while (i < payload.length) {
    final dif = payload[i++];
    if (dif == 0x2F) continue;

    final difData = dif & 0x0F;
    bool hasDife  = (dif & 0x80) != 0;
    while (hasDife && i < payload.length) {
      final dife = payload[i++]; hasDife = (dife & 0x80) != 0;
    }

    if (difData == 0x0F) {
      // Manufacturer-specific data (Apator)
      // VIF(1B) + alarm_word(4B LE) + history
      if (i + 5 <= payload.length) {
        i++; // VIF
        result.faultsWord = _readInt32Le(payload, i); i += 4;
        final extra = payload.sublist(i);
        _tryExtractHistory(result, extra);
      }
      break;
    }

    final n = _difSize[difData] ?? 0;
    if (n < 0 || i >= payload.length) break;

    // Read VIF
    int vif = payload[i++];
    while ((vif & 0x80) != 0 && i < payload.length) { vif = payload[i++]; }
    final vifClean = vif & 0x7F;

    if (i + n > payload.length) break;
    final valBytes = payload.sublist(i, i + n); i += n;

    if (_volVifs.containsKey(vifClean) && n == 4) {
      final raw = _readInt32Le(Uint8List.fromList(valBytes), 0);
      result.volumeM3 ??= raw * _volVifs[vifClean]!;
      result.volumeM3 = double.parse(result.volumeM3!.toStringAsFixed(3));
    } else if (vifClean == 0x6D && n == 4) {
      result.timestamp ??= _typeFDatetime(Uint8List.fromList(valBytes));
    }
  }

  return result;
}

void _tryExtractHistory(OmsResult result, Uint8List extra) {
  final maxImpulses = ((result.volumeM3 ?? 0) * 1000).toInt() + 10001;
  for (int start = 0; start < math.min(20, extra.length); start += 2) {
    final vals = <HistRaw>[];
    int off = start;
    while (off + 4 <= extra.length) {
      final v = _readInt32Le(extra, off);
      if (v == 0 || v > maxImpulses) break;
      vals.add(HistRaw(v));
      off += 4;
    }
    if (vals.length >= 3) {
      result.history = vals;
      return;
    }
  }
}

// ── Alarm decoding ────────────────────────────────────────────────────────────

const Map<int, String> _faultsCurrent = {
  15: 'Flow below minimum',
  14: 'Flow above maximum',
  13: 'Reverse flow',
  12: 'No flow',
  11: 'Water leak',
  10: 'Disconnection',
   9: 'Magnetic field',
};

const Map<int, String> _faultsMemory = {
  8: 'Low battery',
  7: 'Flow below minimum (hist.)',
  6: 'Flow above maximum (hist.)',
  5: 'Reverse flow (hist.)',
  4: 'No flow (hist.)',
  3: 'Water leak (hist.)',
  2: 'Disconnection (hist.)',
  1: 'Magnetic field (hist.)',
  0: 'Battery lifetime exceeded',
};

List<String> decodeAlarms(int? word) {
  if (word == null) return [];
  if (word == 0) return ['OK'];
  final all = {..._faultsCurrent, ..._faultsMemory};
  return all.entries
      .where((e) => word & (1 << e.key) != 0)
      .map((e) => e.value)
      .toList()
    ..sort((a, b) =>
        all.entries.firstWhere((e) => e.value == b).key -
        all.entries.firstWhere((e) => e.value == a).key);
}

// ── Date helpers for history ──────────────────────────────────────────────────

DateTime _monthEnd(int year, int month) {
  final nextMonth = month == 12 ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);
  return nextMonth.subtract(const Duration(minutes: 1)); // last day 23:59
}

(int, int) _prevMonth(int year, int month) =>
    month == 1 ? (year - 1, 12) : (year, month - 1);

/// Attach calendar dates to raw history impulse values.
List<({DateTime? date, double volumeM3})> buildHistoryDates(
  List<HistRaw> raw,
  DateTime? readingDate,
) {
  final result = <({DateTime? date, double volumeM3})>[];
  var year  = readingDate?.year  ?? 0;
  var month = readingDate?.month ?? 0;
  for (final h in raw) {
    if (readingDate != null) {
      (year, month) = _prevMonth(year, month);
    }
    result.add((
      date: readingDate != null ? _monthEnd(year, month) : null,
      volumeM3: double.parse((h.impulses * 0.001).toStringAsFixed(3)),
    ));
  }
  return result;
}

// ── Techem manufacturer detection ─────────────────────────────────────────────
//
// Techem M-field bytes (LE in frame): 0x68, 0x50  → manufacturer code "TCH"
// CI=0xA2 → MK Radio 3 (unencrypted water meter, cold/warm)
// CI=0xA0 → FHKV Data III (unencrypted HCA)

bool isTechFrame(Uint8List mBytes) =>
    mBytes.length >= 2 && mBytes[0] == 0x68 && mBytes[1] == 0x50;

// ── Techem MK Radio 3 – CI=0xA2 ──────────────────────────────────────────────
//
// Manufacturer-specific payload (no OMS DIF/VIF):
//   payload[0]   = 0x06 (constant subtype byte)
//   payload[1-2] = prev_date LE: day=b&0x1F, month=(b>>5)&0x0F, year=2000+((b>>9)&0x3F)
//   payload[3-4] = previous period cumulative [LE] / 10 → m³
//   payload[5-6] = curr_date LE: day=(b>>4)&0x1F, month=(b>>9)&0x0F (year derived)
//   payload[7-8] = current period cumulative [LE] / 10 → m³
//   total_m3 = prev_m3 + curr_m3
//
// Device type 0x62 = cold water, 0x72 = warm water.
// Source: wmbusmeters driver_mkradio3.cc

class TechWaterResult {
  final double prevM3;
  final double currM3;
  final double totalM3;
  final DateTime? prevDate;
  final DateTime? currDate;
  final bool isWarm; // true=warm water (0x72), false=cold (0x62)

  const TechWaterResult({
    required this.prevM3,
    required this.currM3,
    required this.totalM3,
    this.prevDate,
    this.currDate,
    required this.isWarm,
  });
}

TechWaterResult? parseTechWater(Uint8List blockData) {
  // blockData[0] = CI (0xA2), payload starts at [1]
  if (blockData.length < 10) return null;
  final p = blockData.sublist(1); // payload after CI

  final prevDateVal = (p[2] << 8) | p[1];
  final dayPrev   = prevDateVal & 0x1F;
  final monthPrev = (prevDateVal >> 5) & 0x0F;
  final yearPrev  = 2000 + ((prevDateVal >> 9) & 0x3F);

  final prevRaw = (p[4] << 8) | p[3];
  final prevM3  = prevRaw / 10.0;

  final currDateVal = (p[6] << 8) | p[5];
  final dayCurr   = (currDateVal >> 4) & 0x1F;
  final monthCurr = (currDateVal >> 9) & 0x0F;
  var   yearCurr  = yearPrev;
  if (monthCurr < monthPrev ||
      (monthCurr == monthPrev && dayCurr <= dayPrev)) yearCurr++;

  final currRaw = (p[8] << 8) | p[7];
  final currM3  = currRaw / 10.0;

  DateTime? prevDate;
  DateTime? currDate;
  try {
    prevDate = DateTime(yearPrev, monthPrev, dayPrev);
    currDate = DateTime(yearCurr, monthCurr.clamp(1, 12), dayCurr.clamp(1, 31));
  } catch (_) {}

  return TechWaterResult(
    prevM3:   double.parse(prevM3.toStringAsFixed(3)),
    currM3:   double.parse(currM3.toStringAsFixed(3)),
    totalM3:  double.parse((prevM3 + currM3).toStringAsFixed(3)),
    prevDate: prevDate,
    currDate: currDate,
    isWarm:   false, // caller sets based on device type
  );
}

// ── Techem FHKV Data III – CI=0xA0 ───────────────────────────────────────────
//
// Manufacturer-specific payload (no OMS DIF/VIF, unencrypted):
//   payload[0]   = 0x11 (constant, subtype)
//   payload[1-2] = prev_date LE (same bit layout as mkradio3)
//   payload[3-4] = previous HCA [LE] (dimensionless heat units)
//   payload[5-6] = curr_date LE
//   payload[7-8] = current HCA [LE]
//   payload[9-12]= room_temp [LE]/100 °C, radiator_temp [LE]/100 °C
//                  (offset=10 if dll_version==0x94)
//
// Source: wmbusmeters driver_fhkvdataiii.cc

class TechHcaResult {
  final int prevHca;
  final int currHca;
  final DateTime? prevDate;
  final DateTime? currDate;
  final double? tempRoomC;
  final double? tempRadiatorC;

  const TechHcaResult({
    required this.prevHca,
    required this.currHca,
    this.prevDate,
    this.currDate,
    this.tempRoomC,
    this.tempRadiatorC,
  });
}

TechHcaResult? parseTechHca(Uint8List blockData, {int dllVersion = 0x69}) {
  // blockData[0] = CI (0xA0), payload starts at [1]
  if (blockData.length < 15) return null;
  final p = blockData.sublist(1);

  final prevDateVal = (p[2] << 8) | p[1];
  final dayPrev   = prevDateVal & 0x1F;
  final monthPrev = (prevDateVal >> 5) & 0x0F;
  final yearPrev  = 2000 + ((prevDateVal >> 9) & 0x3F);

  final prevHca = (p[4] << 8) | p[3];

  final currDateVal = (p[6] << 8) | p[5];
  final dayCurr   = ((currDateVal >> 4) & 0x1F).clamp(1, 31);
  final monthCurr = ((currDateVal >> 9) & 0x0F).clamp(1, 12);
  var   yearCurr  = yearPrev;
  if (monthCurr < monthPrev ||
      (monthCurr == monthPrev && dayCurr <= dayPrev)) yearCurr++;

  final currHca = (p[8] << 8) | p[7];

  final offset = (dllVersion == 0x94) ? 10 : 9;
  double? tempRoom, tempRad;
  if (p.length >= offset + 4) {
    tempRoom = ((p[offset + 1] << 8) | p[offset]) / 100.0;
    tempRad  = ((p[offset + 3] << 8) | p[offset + 2]) / 100.0;
  }

  DateTime? prevDate;
  DateTime? currDate;
  try {
    prevDate = DateTime(yearPrev, monthPrev, dayPrev);
    currDate = DateTime(yearCurr, monthCurr, dayCurr);
  } catch (_) {}

  return TechHcaResult(
    prevHca:       prevHca,
    currHca:       currHca,
    prevDate:      prevDate,
    currDate:      currDate,
    tempRoomC:     tempRoom,
    tempRadiatorC: tempRad,
  );
}

// ── Apator 162 – CI=0x7A (TPL-direct, AES-128-CBC) ───────────────────────────
//
// Frame layout (blockData after CRC strip):
//   bd[0]   = CI (0x7A)
//   bd[1]   = TPL_ACC (used in IV)
//   bd[2]   = Status
//   bd[3-4] = Config word LE → bits[12:8]=n_enc_blocks, bits[4:0]=sec_mode
//   bd[5+]  = encrypted data (n_enc_blocks * 16 bytes)
//
// IV = M_field(2B) + A_field(6B) + TPL_ACC×8
//
// Plaintext (Apator 162 proprietary format):
//   byte 0-1 = 0x2F 0x2F
//   byte 2   = 0x0F (manufacturer-specific marker)
//   bytes 3-9 = 7-byte status block (skip)
//   bytes 10+ = sequential tagged records:
//     tag(1B) + data(n bytes)
//     tag 0x10 → total volume as 4B LE uint32 in litres → /1000 = m³
//     tag 0x7B → monthly history: 1B count + 12×4B cumulative litres LE
//     (other tags have known fixed sizes per Apator IXML grammar)
//
// Source: wmbusmeters apator162.xmq driver

/// Returns true if [mBytes] belong to an Apator frame (manufacturer "APA").
/// M-field LE bytes: 0x01, 0x06  (manufacturer code 0x0601 = "APA").
bool isApaFrame(Uint8List mBytes) =>
    mBytes.length >= 2 && mBytes[0] == 0x01 && mBytes[1] == 0x06;

/// Returns the size in *data* bytes for a given Apator 162 tag byte.
/// Returns null for unknown tags (caller must abort parsing).
int? _apa162TagSize(int tag) {
  if (tag == 0xFF) return null;  // end marker
  if (tag == 0x00) return 4;
  if (tag == 0x01) return 3;
  if (tag == 0x10) return 4;   // total volume (litres, LE uint32)
  if (tag == 0x11) return 2;
  if (tag == 0x40) return 6;
  if (tag == 0x41) return 2;
  if (tag == 0x42) return 4;
  if (tag == 0x43) return 2;
  if (tag == 0x44) return 3;
  // History tags 0x71..0x7B: 1 byte count + (tag-0x70)*4 bytes
  if (tag >= 0x71 && tag <= 0x7B) return 1 + (tag - 0x70) * 4;
  // Extended tags 0x80..0x8F (Apator-specific)
  if ((tag >= 0x80 && tag <= 0x84) || tag == 0x86 || tag == 0x87) return 10;
  if (tag == 0x85 || tag == 0x88 || tag == 0x8F) return 11;
  if (tag == 0x8A) return 9;
  if (tag == 0x8B || tag == 0x8C) return 6;
  if (tag == 0x8E) return 7;
  // A-range tags
  if (tag == 0xA0 || tag == 0xA1 || tag == 0xA4) return 4;
  if (tag == 0xA2 || tag == 0xA5 || tag == 0xA9 || tag == 0xAF) return 1;
  if (tag == 0xA3) return 7;
  if (tag == 0xA6) return 3;
  if (tag >= 0xA7 && tag <= 0xAD) return 2;
  if (tag == 0xB0) return 5;
  if (tag == 0xB1 || tag == 0xB3) return 8;
  if (tag == 0xB2 || tag == 0xB5) return 16;
  if (tag == 0xB4) return 2;
  if (tag >= 0xB6 && tag <= 0xBF) return 3;
  if (tag >= 0xC0 && tag <= 0xC7) return 3;
  if (tag == 0xD0 || tag == 0xD3) return 3;
  return null;  // unknown → stop
}

class Apa162HistEntry {
  final int month;  // 1-based offset from reading date (1=last month)
  final double volumeM3;
  const Apa162HistEntry({required this.month, required this.volumeM3});
}

class Apa162Result {
  double? totalM3;
  List<Apa162HistEntry> history = [];
}

/// Returns true if [payload] (decrypted blockData) looks like Apator 162 format.
bool isApa162Payload(Uint8List payload) =>
    payload.length >= 3 &&
    payload[0] == 0x2F &&
    payload[1] == 0x2F &&
    payload[2] == 0x0F;

/// Parse decrypted Apator 162 plaintext payload.
/// [payload] is the full plaintext starting with 0x2F 0x2F.
Apa162Result parseApa162Payload(Uint8List payload) {
  final result = Apa162Result();

  // Skip 0x2F 0x2F + 0x0F marker + 7-byte status block = 10 bytes
  if (payload.length < 10) return result;
  int i = 10;

  while (i < payload.length) {
    final tag = payload[i++];
    final size = _apa162TagSize(tag);
    if (size == null || i + size > payload.length) break;

    if (tag == 0x10) {
      // Total volume in litres (LE uint32)
      final litres = payload[i] |
          (payload[i + 1] << 8) |
          (payload[i + 2] << 16) |
          (payload[i + 3] << 24);
      result.totalM3 = double.parse((litres / 1000.0).toStringAsFixed(3));
    } else if (tag >= 0x71 && tag <= 0x7B) {
      // First byte is a type/mode byte (not a count) — number of entries is
      // determined by the tag: n = (size - 1) / 4  (same as Python decoder).
      final nVals = (size - 1) ~/ 4;
      final entries = <Apa162HistEntry>[];
      for (int m = 0; m < nVals && i + 1 + m * 4 + 4 <= payload.length; m++) {
        final off = i + 1 + m * 4;
        final litres = payload[off] |
            (payload[off + 1] << 8) |
            (payload[off + 2] << 16) |
            (payload[off + 3] << 24);
        if (litres > 0) {
          entries.add(Apa162HistEntry(
            month:    m + 1,
            volumeM3: double.parse((litres / 1000.0).toStringAsFixed(3)),
          ));
        }
      }
      if (result.history.isEmpty) result.history = entries;
    }

    i += size;
  }

  return result;
}
