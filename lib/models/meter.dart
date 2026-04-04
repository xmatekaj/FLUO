// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE

enum MeterStatus { pending, ok, alarm, noKey, failed }

extension MeterStatusLabel on MeterStatus {
  String get label {
    switch (this) {
      case MeterStatus.pending: return '⏳ Pending';
      case MeterStatus.ok:      return '✅ OK';
      case MeterStatus.alarm:   return '⚠️ Alarm';
      case MeterStatus.noKey:   return '🔑 No key';
      case MeterStatus.failed:  return '❌ Failed';
    }
  }
}

class HistoryEntry {
  final DateTime? date;
  final double volumeM3;
  const HistoryEntry({this.date, required this.volumeM3});
}

class Meter {
  final String building;
  final String staircase;
  final String apartment;
  final String serial;
  final int? radioNum;       // null = not yet installed
  final List<int>? aesKey;   // 16 bytes, null = no key

  MeterStatus status;
  double? volumeM3;
  DateTime? readAt;
  List<String> alarms;
  List<HistoryEntry> history;

  Meter({
    required this.building,
    required this.staircase,
    required this.apartment,
    required this.serial,
    required this.radioNum,
    required this.aesKey,
    this.status = MeterStatus.pending,
    this.volumeM3,
    this.readAt,
    List<String>? alarms,
    List<HistoryEntry>? history,
  })  : alarms = alarms ?? [],
        history = history ?? [];

  bool get hasKey => aesKey != null && aesKey!.length == 16;
  bool get isInstalled => radioNum != null;

  String get displayId => radioNum?.toString() ?? '—';

  void reset() {
    status = isInstalled ? MeterStatus.pending : MeterStatus.noKey;
    volumeM3 = null;
    readAt = null;
    alarms = [];
    history = [];
  }
}

// ── Unknown meter (not in CSV) ────────────────────────────────────────────────

enum UnknownMeterKind { techWater, techHca, zeroKeyOk, zeroKeyFail }

class UnknownMeter {
  final int radioNum;
  UnknownMeterKind kind;

  // Water (Techem A2 or Apator zero-key)
  double? totalM3;
  double? prevM3;
  double? currM3;
  DateTime? prevDate;
  DateTime? currDate;
  List<String> alarms;
  bool isWarmWater;   // for Techem A2

  // HCA (Techem A0)
  int? prevHca;
  int? currHca;
  double? tempRoomC;
  double? tempRadiatorC;

  List<HistoryEntry> history;

  DateTime readAt;
  int frameCount;

  UnknownMeter({
    required this.radioNum,
    required this.kind,
    this.totalM3,
    this.prevM3,
    this.currM3,
    this.prevDate,
    this.currDate,
    List<String>? alarms,
    this.isWarmWater = false,
    this.prevHca,
    this.currHca,
    this.tempRoomC,
    this.tempRadiatorC,
    List<HistoryEntry>? history,
    required this.readAt,
    this.frameCount = 1,
  })  : alarms = alarms ?? [],
        history = history ?? [];

  bool get isDecoded =>
      kind == UnknownMeterKind.techWater ||
      kind == UnknownMeterKind.techHca   ||
      kind == UnknownMeterKind.zeroKeyOk;

  String get kindLabel {
    switch (kind) {
      case UnknownMeterKind.techWater:   return isWarmWater ? '♨ Techem warm' : '💧 Techem cold';
      case UnknownMeterKind.techHca:     return '🌡 Techem HCA';
      case UnknownMeterKind.zeroKeyOk:   return '✅ Zero-key OK';
      case UnknownMeterKind.zeroKeyFail: return '❌ Unknown';
    }
  }
}
