// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE

import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import '../models/meter.dart';

// Column name sets (case-insensitive)
const _radioCols  = {'radio_number', 'radio number', 'numer_radiowy', 'numer radiowy', 'radio id'};
const _keyCols    = {'wmbus key', 'wm_bus_key', 'klucz wmbus', 'key'};
const _serialCols = {'meter_serial', 'meter serial', 'numer_wodomierza', 'nr wodomierza', 'serial'};
const _staircaseCols = {'staircase', 'klatka'};
const _aptCols    = {'apartment', 'lokal', 'mieszkanie'};
const _bldgCols   = {'building', 'budynek'};

int? _findCol(List<String> header, Set<String> candidates) {
  for (int i = 0; i < header.length; i++) {
    if (candidates.contains(header[i].trim().toLowerCase())) return i;
  }
  return null;
}

String _get(List<String> row, int? idx) =>
    (idx != null && idx < row.length) ? row[idx].trim() : '';

/// Parse the merged meters CSV (output of prepare_meters.py).
/// Returns list of [Meter] with AES keys embedded.
List<Meter> parseMeters(String csvContent) {
  final rows = const CsvToListConverter(
    fieldDelimiter: ';',
    eol: '\n',
    shouldParseNumbers: false,
  ).convert(csvContent);

  if (rows.isEmpty) throw FormatException('Empty CSV');

  final header = rows[0].map((e) => e.toString()).toList();
  final iRadio  = _findCol(header, _radioCols);
  final iKey    = _findCol(header, _keyCols);
  final iSerial = _findCol(header, _serialCols);
  final iStair  = _findCol(header, _staircaseCols);
  final iApt    = _findCol(header, _aptCols);
  final iBldg   = _findCol(header, _bldgCols);

  if (iRadio == null) {
    throw FormatException(
      'Meters CSV must have a radio-number column.\nFound: $header',
    );
  }

  final meters = <Meter>[];
  for (final rawRow in rows.skip(1)) {
    final row = rawRow.map((e) => e.toString()).toList();
    if (row.every((c) => c.trim().isEmpty)) continue;

    final radioStr = _get(row, iRadio);
    final int? radioNum = int.tryParse(radioStr);

    List<int>? key;
    final keyHex = _get(row, iKey);
    if (keyHex.length == 32) {
      try {
        key = List.generate(16, (i) => int.parse(keyHex.substring(i * 2, i * 2 + 2), radix: 16));
      } catch (_) {}
    }

    meters.add(Meter(
      building:  _get(row, iBldg),
      staircase: _get(row, iStair),
      apartment: _get(row, iApt),
      serial:    _get(row, iSerial),
      radioNum:  radioNum,
      aesKey:    key,
      status:    radioNum != null ? MeterStatus.pending : MeterStatus.noKey,
    ));
  }
  return meters;
}

String _fmtDate(DateTime? dt) {
  if (dt == null) return '';
  return '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')}';
}

String _fmtDateTime(DateTime dt) =>
    '${_fmtDate(dt)} ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}:${dt.second.toString().padLeft(2,'0')}';

/// Export results to a CSV string (one row per meter + history in separate rows).
String exportToCsv(List<Meter> meters) {
  final rows = <List<String>>[
    ['Building', 'Staircase', 'Apartment', 'Meter S/N', 'Radio ID',
     'Status', 'Volume (m³)', 'Read at', 'Alarms',
     'History date', 'History volume (m³)'],
  ];
  for (final m in meters) {
    final alarms = m.alarms.where((a) => a != 'OK').join(', ');
    final readAt = m.readAt != null ? _fmtDateTime(m.readAt!) : '';
    final vol    = m.volumeM3?.toStringAsFixed(3) ?? '';

    if (m.history.isEmpty) {
      rows.add([
        m.building, m.staircase, m.apartment, m.serial, m.displayId,
        m.status.label, vol, readAt, alarms, '', '',
      ]);
    } else {
      // First row: meter info + first history entry
      rows.add([
        m.building, m.staircase, m.apartment, m.serial, m.displayId,
        m.status.label, vol, readAt, alarms,
        _fmtDate(m.history.first.date),
        m.history.first.volumeM3.toStringAsFixed(3),
      ]);
      // Additional rows: only history (building etc. empty for readability)
      for (final h in m.history.skip(1)) {
        rows.add(['', '', '', '', '', '', '', '', '',
          _fmtDate(h.date), h.volumeM3.toStringAsFixed(3)]);
      }
    }
  }
  return const ListToCsvConverter(fieldDelimiter: ';').convert(rows);
}

/// Export unknown meters to CSV string.
String exportUnknownToCsv(List<UnknownMeter> unknown) {
  final rows = <List<String>>[
    ['Radio ID', 'Kind', 'Total (m³)', 'Prev (m³)', 'Curr (m³)',
     'Prev date', 'Curr date', 'Alarms', 'Frames', 'Last seen'],
  ];
  for (final m in unknown) {
    final alarms = m.alarms.where((a) => a != 'OK').join(', ');
    rows.add([
      m.radioNum.toString(),
      m.kindLabel,
      m.totalM3?.toStringAsFixed(3) ?? '',
      m.prevM3?.toStringAsFixed(3) ?? '',
      m.currM3?.toStringAsFixed(3) ?? '',
      _fmtDate(m.prevDate),
      _fmtDate(m.currDate),
      alarms,
      m.frameCount.toString(),
      _fmtDateTime(m.readAt),
    ]);
  }
  return const ListToCsvConverter(fieldDelimiter: ';').convert(rows);
}

/// Export raw frames buffer to CSV string.
String exportRawFramesToCsv(List<({DateTime ts, int? radioNum, String reason, String hex})> frames) {
  final rows = <List<String>>[
    ['Timestamp', 'Radio ID', 'Reason', 'Raw hex'],
  ];
  for (final f in frames) {
    rows.add([
      _fmtDateTime(f.ts),
      f.radioNum?.toString() ?? '',
      f.reason,
      f.hex,
    ]);
  }
  return const ListToCsvConverter(fieldDelimiter: ';').convert(rows);
}

/// Save CSV to Downloads / temp and return file path.
Future<String> saveCsvFile(String content, String filename) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$filename');
  await file.writeAsString(content, encoding: utf8);
  return file.path;
}
