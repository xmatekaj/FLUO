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

/// Extract complete W-MBus frames from Apator BT module in FramesListening mode.
///
/// Protocol: SOF=0x02 [escaped payload] EOF=0x03
/// Escape: 0x10 XX → byte (XX + 128)
///
/// After unescaping, the payload is a raw wMBus frame (L + C + M + A + data).
/// We prepend SOF=0xFF so the result is compatible with [parseRawFrame].
///
/// Consumed bytes are removed from the front of [buf].
List<Uint8List> extractBtFrames(List<int> buf) {
  final frames = <Uint8List>[];
  int i = 0;

  while (i < buf.length) {
    // Find SOF = 0x02
    if (buf[i] != 0x02) { i++; continue; }

    // Find EOF = 0x03
    int end = -1;
    for (int j = i + 1; j < buf.length; j++) {
      if (buf[j] == 0x03) { end = j; break; }
    }
    if (end < 0) break; // incomplete frame, wait for more data

    // Unescape payload between SOF and EOF
    final payload = <int>[];
    bool escaped = false;
    for (int j = i + 1; j < end; j++) {
      if (escaped) {
        payload.add((buf[j] + 128) & 0xFF);
        escaped = false;
      } else if (buf[j] == 0x10) {
        escaped = true;
      } else {
        payload.add(buf[j]);
      }
    }

    if (payload.length > 2) {
      // Skip 2-byte BT module prefix (RSSI + status) then prepend 0xFF SOF
      frames.add(Uint8List.fromList([0xFF, ...payload.sublist(2)]));
    }
    i = end + 1;
  }

  buf.removeRange(0, i);
  return frames;
}

/// Extract complete W-MBus frames from a mutable buffer.
/// Consumed bytes are removed from the front of [buf].
/// Returns list of complete raw frames.
///
/// Adeunis ARF8020AA emits two formats:
///   RX broadcasts:  0xFF [L] [C=0x44] [M] [A] [data...]   — length = L+2
///   RX RSP-UD:      0xFF [L] [C=0x08] [M] [A] [CI=0x7A] [TPL+enc] [trailer]
///                   — actual length is ~L+13B due to extra Adeunis trailer.
///   TX bidir:       0xFF 0xFE [...]                       — skipped here.
List<Uint8List> extractFrames(List<int> buf) {
  final frames = <Uint8List>[];
  int i = 0;
  while (i < buf.length) {
    if (buf[i] != 0xFF) { i++; continue; }
    if (i + 1 >= buf.length) break;
    // Skip TX bidirectional frames (FF FE prefix) — handled separately
    if (buf[i + 1] == 0xFE) {
      // Find next SOF after at least 12 bytes; consume up to it
      int end = -1;
      for (int j = i + 12; j < buf.length; j++) {
        if (buf[j] == 0xFF && (j + 1 >= buf.length || buf[j + 1] != 0xFE)) {
          end = j; break;
        }
      }
      if (end < 0) break; // wait for more
      i = end;
      continue;
    }
    final L = buf[i + 1];
    final payloadLen = L - 9;
    if (payloadLen <= 0) { i++; continue; }

    // Standard frame length = SOF(1) + L(1) + C(1) + M(2) + A(6) + payload
    int total = 11 + payloadLen;

    // Special: APA RSP-UD (C=0x08, M=0x0601) frames have ~13B extra trailer
    // (Adeunis-specific RSSI/AFC bytes). Need full 49B (= L+2+13).
    if (i + 5 < buf.length &&
        buf[i + 2] == 0x08 && buf[i + 3] == 0x01 && buf[i + 4] == 0x06) {
      const trailerLen = 13;
      // Wait until we have either next SOF or at least total+trailerLen bytes
      final maxEnd = math.min(i + 64, buf.length);
      int extEnd = -1;
      for (int j = i + total; j < maxEnd; j++) {
        if (buf[j] == 0xFF) { extEnd = j; break; }
      }
      if (extEnd > 0) {
        total = extEnd - i;
      } else if (buf.length - i >= total + trailerLen) {
        total = total + trailerLen;
      } else {
        // Not enough data yet — break and wait for more bytes
        break;
      }
    }

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
  final int cField;         // C-field (0x44=broadcast, 0x08=RSP-UD, 0x53/0x73=SND-UD, ...)
  final Uint8List mBytes;   // 2 bytes
  final Uint8List aBytes;   // 6 bytes
  final int sw;
  final int hw;
  final int radioNum;
  final Uint8List blockData;
  final bool crcOk;
  ParsedFrame({
    required this.lField,
    required this.cField,
    required this.mBytes,
    required this.aBytes,
    required this.sw,
    required this.hw,
    required this.radioNum,
    required this.blockData,
    required this.crcOk,
  });

  /// True if this is a service response (RSP-UD from slave to master).
  bool get isRspUd => cField == 0x08 || cField == 0x18 || cField == 0x88;

  /// True if this is a standard broadcast (SND-NR).
  bool get isBroadcast => cField == 0x44;
}

/// Parse raw frame bytes (SOF=0xFF prefix).
/// Frame layout from Adeunis-RF dongle (no header CRC):
///   SOF(1) + L(1) + C(1) + M(2) + A(6) + dataBlocks(payload with block CRCs)
ParsedFrame? parseRawFrame(Uint8List raw) {
  if (raw.isEmpty || raw[0] != 0xFF || raw.length < 12) return null;

  final lField    = raw[1];
  final cField    = raw[2];
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

  // Data payload starts at raw[11] (no header CRC, no block CRCs from this dongle).
  // Take from byte 11 to end of raw frame — for RSP-UD (C=0x08) the actual
  // encrypted block extends beyond L (extractor accounts for Adeunis trailer).
  final blockData = raw.sublist(11);
  final crcOk = true; // dongle strips block CRCs; skip CRC verification

  return ParsedFrame(
    lField: lField,
    cField: cField,
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
  /// Raw tagged values from the plaintext (tag id → raw data bytes).
  /// Useful for service responses (RSP-UD) where tags carry register values.
  Map<int, Uint8List> rawTags = {};
}

/// Returns true if [payload] (decrypted blockData) looks like Apator 162 format.
bool isApa162Payload(Uint8List payload) =>
    payload.length >= 3 &&
    payload[0] == 0x2F &&
    payload[1] == 0x2F &&
    payload[2] == 0x0F;

// ── Apator T2 READ command builder (master→slave) ────────────────────────────
//
// Reverse engineered from Inkasent PC 4 .NET assemblies (AT.dll). Format:
//   wMBus DLL: [L] [C=0x5B REQ-UD2] [M=0x0601 APA] [A=4B BCD ID + SW + HW]
//   CI=0x5B (CMDToDevice12Bytes)
//   Long Header (12B): A(4) + M(2) + SW + Hw + ACC + Status + ConfigField(2)
//   Encrypted application data (AES-CBC mode 5):
//     [2F 2F]              ← verification bytes
//     [0F]                 ← DIF manufacturer-specific
//     [4B RtcClock4B]      ← OMS Type-F datetime
//     [1B Codes.Read = 1]  ← opcode
//     [N×1B register IDs]
//     [0xFF padding]
//     [CRC-16 wMBus 2B]
//     [0x2F padding to next 16B boundary]
//   IV = M(2) + ID(4) + SW(1) + Hw(1) + ACC×8

/// Encode a DateTime as 4-byte OMS Type-F datetime (used by Apator RtcClock4B).
Uint8List encodeRtcClock4B(DateTime dt, {bool summerTime = false, bool activateTimeChange = false}) {
  final dow = dt.weekday; // 1..7 ISO (Monday=1, Sunday=7)
  final out = Uint8List(4);
  out[0] = ((dt.minute & 0x3F) | ((dt.hour << 6) & 0xC0)) & 0xFF;
  out[1] = ((dt.day & 0x1F) | ((dt.hour << 3) & 0xE0)) & 0xFF;
  out[2] = ((dt.month & 0x0F) | (summerTime ? 0x10 : 0) | ((dow << 5) & 0xE0)) & 0xFF;
  out[3] = (((dt.year - 2000) & 0x7F) | (activateTimeChange ? 0x80 : 0)) & 0xFF;
  return out;
}

/// Convert decimal radio number to 4-byte BCD little-endian (as used in A-field).
/// e.g. 1243242 → bytes [0x42, 0x32, 0x24, 0x01]
Uint8List radioToBcdLE(int radioNumber) {
  final s = radioNumber.toString().padLeft(8, '0');
  final out = Uint8List(4);
  // Pairs of digits, LE: lowest pair first
  for (int i = 0; i < 4; i++) {
    final hi = int.parse(s[6 - 2 * i]);
    final lo = int.parse(s[7 - 2 * i]);
    out[i] = (hi << 4) | lo;
  }
  return out;
}

/// Build the encrypted application data payload (before AES) for a READ command.
/// Layout: [2F 2F][0F DIF][clock 4B][Code=0x01][reg IDs][0xFF padding][CRC 2B][0x2F pad to 16B]
Uint8List buildApatorReadPlaintext(List<int> regIds, DateTime now) {
  final clock = encodeRtcClock4B(now);
  // parametersData = 4B clock + 1B Code.Read + N×reg_id
  final params = <int>[...clock, 0x01, ...regIds];

  // AdjustDataSizeAndAppendCrc (from decompiled C#):
  //   num = params.length + 2 (CRC) + 1 (DIF)
  //   num3 = round up to (multiple of 16) such that DIF+params+padding+CRC = 16N
  final num = params.length + 3;
  final mod = num % 16;
  final num3 = (mod <= 14) ? (num + 14 - mod) : (num + 16 - mod + 14);
  // base.Data length = num3 - 1 (DIF will be embedded separately via DIB, but we keep it inline)

  // Build array: [0x0F][params][0xFF padding][CRC 2B]
  // Length matches C# logic: array.Length = num3 - 1; but we add DIF+CRC explicitly here.
  final preCrc = Uint8List(num3 - 1);
  preCrc[0] = 0x0F;
  for (int i = 0; i < params.length; i++) {
    preCrc[1 + i] = params[i] & 0xFF;
  }
  // Fill rest with 0xFF (before CRC slot)
  for (int i = 1 + params.length; i < preCrc.length - 2; i++) {
    preCrc[i] = 0xFF;
  }
  // CRC over [0..length-3] inclusive (i.e. length-2 bytes — DIF + params + padding without CRC)
  // Crc16Wmbus.CalculateCrc XORs result bytes with 0xFF (~ bitwise NOT in C#)
  final crc = _crc16(preCrc.sublist(0, preCrc.length - 2));
  preCrc[preCrc.length - 2] = ((crc >> 8) & 0xFF) ^ 0xFF;
  preCrc[preCrc.length - 1] = (crc & 0xFF) ^ 0xFF;

  // Final plaintext = [2F 2F] + preCrc[1..] (skip DIF — it's at start of preCrc)
  // Wait: the C# code shifts left to remove DIF. But the plaintext seen on the wire
  // INCLUDES the 0x0F marker (we observed it in RSP-UD). So we keep DIF in plaintext.
  // Plaintext to encrypt: [2F 2F] + preCrc (which is [0F + params + 0xFF pad + CRC])
  // Total = 2 + (num3 - 1) = num3 + 1 bytes.
  // Pad to 16B boundary with 0x2F.
  final totalSize = ((2 + preCrc.length + 15) ~/ 16) * 16;
  final plaintext = Uint8List(totalSize);
  plaintext[0] = 0x2F;
  plaintext[1] = 0x2F;
  plaintext.setRange(2, 2 + preCrc.length, preCrc);
  for (int i = 2 + preCrc.length; i < totalSize; i++) {
    plaintext[i] = 0x2F;
  }
  return plaintext;
}

/// AES-CBC encrypt with given key + IV. Pads to 16B if needed.
Uint8List? encryptCbc(List<int> key, Uint8List iv, Uint8List plaintext) {
  if (plaintext.length % 16 != 0) return null;
  try {
    final k = enc.Key(Uint8List.fromList(key));
    final i = enc.IV(iv);
    final cipher = enc.Encrypter(enc.AES(k, mode: enc.AESMode.cbc, padding: null));
    return Uint8List.fromList(
      cipher.encryptBytes(plaintext, iv: i).bytes,
    );
  } catch (_) {
    return null;
  }
}

/// Compute wMBus block-level CRC-16 (poly 0x3D65, XOR result with 0xFF).
Uint8List _wmbusBlockCrc(Uint8List block) {
  final c = _crc16(block);
  return Uint8List.fromList([
    ((c >> 8) & 0xFF) ^ 0xFF,
    (c & 0xFF) ^ 0xFF,
  ]);
}

/// Add wMBus mode A block-level CRC-16 to a frame.
/// Layout: [10B header] [2B CRC] [16B block] [2B CRC] [16B block] [2B CRC] ...
/// Returns new buffer with CRCs inserted.
Uint8List addWmbusBlockCrcs(Uint8List frameNoCrc) {
  // First block is 10 bytes (header = L+C+M+A+Sw+Hw)
  if (frameNoCrc.length < 10) return frameNoCrc;
  final result = BytesBuilder();
  // Header block (10B)
  final headerBlock = frameNoCrc.sublist(0, 10);
  result.add(headerBlock);
  result.add(_wmbusBlockCrc(headerBlock));
  // Subsequent data blocks of up to 16B
  int i = 10;
  while (i < frameNoCrc.length) {
    final blockLen = math.min(16, frameNoCrc.length - i);
    final block = frameNoCrc.sublist(i, i + blockLen);
    result.add(block);
    result.add(_wmbusBlockCrc(block));
    i += blockLen;
  }
  return result.toBytes();
}

/// Build full T2 READ command frame (without Adeunis FF FE prefix).
/// Adeunis txT2Frame() will prepend FF FE.
/// Returns: [L][C=5B][M=0106][A=BCD+SW+HW][CI=5B][LongHeader 12B][encrypted N*16B]
/// With [withBlockCrcs] = true also adds wMBus mode A block-level CRC-16 after
/// each 16-byte block (some dongles require this; some add automatically).
Uint8List buildApatorReadFrame({
  required int radioNumber,
  required int sw,
  required int hw,
  required int accessNumber,
  required List<int> regIds,
  required DateTime now,
  required List<int> aesKey,
  bool withBlockCrcs = false,
}) {
  final bcdA = radioToBcdLE(radioNumber);
  const mField = [0x01, 0x06]; // APA LE

  // Plaintext + AES encrypt
  final plaintext = buildApatorReadPlaintext(regIds, now);
  final nEncBlocks = plaintext.length ~/ 16;
  // ConfigurationField (2B LE) layout per Inkasent decompile:
  //   signature[0]: bits 4-7 = NumberOfEncryptedBlocks, bits 2-3 = ContentOfMessage,
  //                 bit 0 = HopCounter
  //   signature[1]: bits 0-3 = EncryptionMode (5 = AES-CBC mode 5),
  //                 bit 5 = Synchronus, bit 6 = Accesibility,
  //                 bit 7 = BidirectionalCommunication (MUST be set for T2 commands!)
  // For READ master→slave: bidir + encmode=5 + n_enc → signature[1]=0x85, signature[0]=(n<<4)
  final configWord = 0x8000 | (5 << 8) | (nEncBlocks << 4);
  final cfgBytes = [configWord & 0xFF, (configWord >> 8) & 0xFF];

  // IV per long header
  final iv = Uint8List.fromList([
    ...mField,                                                // M (2B)
    bcdA[0], bcdA[1], bcdA[2], bcdA[3],                       // A_id (4B)
    sw, hw,                                                    // SW + HW
    accessNumber, accessNumber, accessNumber, accessNumber,    // ACC × 8
    accessNumber, accessNumber, accessNumber, accessNumber,
  ]);

  final encrypted = encryptCbc(aesKey, iv, plaintext);
  if (encrypted == null) {
    throw Exception('AES encrypt failed');
  }

  // wMBus DLL header
  // Length L = sizeof(C+M+A+CI+LongHeader+encrypted) = 1+2+6+1+12+(N*16) = 22 + N*16
  // Frame: [L][C=5B][M][A=BCD+SW+HW][CI=5B][LongHeader 12B][encrypted]
  // Long Header layout: [A_id 4B BCD][M 2B LE][Sw][MeterType=Hw][AccessNumber][Status=0][Config 2B LE]
  final longHeader = Uint8List.fromList([
    bcdA[0], bcdA[1], bcdA[2], bcdA[3],   // A_id BCD (4B)
    mField[0], mField[1],                  // M (2B LE)
    sw,                                     // SW
    hw,                                     // MeterType / HW
    accessNumber,                           // ACC
    0x00,                                   // Status
    cfgBytes[0], cfgBytes[1],               // Config (2B LE)
  ]);

  // A-field in DLL (6B) = ID(4 BCD) + SW + HW (same as TPL header start; some redundancy)
  final aField = Uint8List.fromList([bcdA[0], bcdA[1], bcdA[2], bcdA[3], sw, hw]);

  // wMBus L = number of bytes AFTER L (= C+M+A+CI+LongHeader+encrypted)
  final innerLen = 1 + 2 + 6 + 1 + 12 + encrypted.length;
  final frame = Uint8List(1 + innerLen);
  int p = 0;
  frame[p++] = innerLen;      // L value
  frame[p++] = 0x5B;          // C-field REQ-UD2
  frame[p++] = mField[0];
  frame[p++] = mField[1];
  for (final b in aField) {
    frame[p++] = b;
  }
  frame[p++] = 0x5B;          // CI-field CMDToDevice12Bytes
  for (final b in longHeader) {
    frame[p++] = b;
  }
  for (final b in encrypted) {
    frame[p++] = b;
  }
  if (withBlockCrcs) {
    return addWmbusBlockCrcs(frame);
  }
  return frame;
}

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

    // Save raw bytes of every tag (skip end-marker 0xFF/empty tags)
    if (size > 0) {
      result.rawTags[tag] = Uint8List.fromList(payload.sublist(i, i + size));
    }

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
