// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE

import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../models/meter.dart';
import '../services/csv_service.dart';
import '../services/serial_service.dart';
import '../services/wmbus_decoder.dart';
import '../widgets/meter_tile.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  // ── State ──────────────────────────────────────────────────────────────────
  List<Meter> _meters = [];
  final Map<int, int> _radioIndex = {}; // radioNum → index in _meters

  // Unknown meters (not in CSV list), decoded with zero key
  final List<UnknownMeter> _unknown = [];
  final Map<int, int> _unknownIndex = {}; // radioNum → index in _unknown

  // Raw frame buffer (all received frames for export)
  final List<({DateTime ts, int? radioNum, String reason, String hex})> _rawFrames = [];

  // Pending frames for meters that are on the list but have no key yet.
  // When meters CSV is reloaded with keys, these are retried.
  final Map<int, List<Uint8List>> _pendingNoKey = {}; // radioNum → raw frames

  late final TabController _tabController;

  List<SerialDevice> _devices = [];
  SerialDevice? _selectedDevice;
  int _baud = 9600;
  bool _connected = false;

  final List<String> _log = [];
  final _scrollLog = ScrollController();
  final _scrollMeters = ScrollController();
  final _scrollUnknown = ScrollController();

  // Filter
  MeterStatus? _filterStatus;
  final _unknownSearchCtrl = TextEditingController();
  String _unknownSearch = '';

  // Subscriptions
  StreamSubscription<Uint8List>? _frameSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<SerialState>? _stateSub;
  StreamSubscription<List<SerialDevice>>? _deviceSub;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    final svc = SerialService.instance;
    svc.startMonitoring();
    _deviceSub = svc.devices.listen((devs) {
      setState(() {
        _devices = devs;
        // Keep selection only if the device is still in the list (by port name).
        // Recreated SerialDevice objects won't be == the old one, so match by label.
        if (_selectedDevice != null) {
          _selectedDevice = devs.where((d) => d.label == _selectedDevice!.label).firstOrNull;
        }
        // Auto-select if exactly one device is available and nothing is selected.
        if (_selectedDevice == null && devs.length == 1) {
          _selectedDevice = devs.first;
        }
      });
    });
    _stateSub = svc.states.listen((s) {
      setState(() => _connected = s == SerialState.connected);
    });
    _frameSub = svc.frames.listen(_handleFrame);
    _errorSub = svc.errors.listen((e) {
      _addLog('ERROR: $e');
      setState(() {});
    });
    svc.refreshDevices();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _frameSub?.cancel();
    _errorSub?.cancel();
    _stateSub?.cancel();
    _deviceSub?.cancel();
    _scrollLog.dispose();
    _scrollMeters.dispose();
    _scrollUnknown.dispose();
    _unknownSearchCtrl.dispose();
    super.dispose();
  }

  // ── Meters file ────────────────────────────────────────────────────────────
  Future<void> _loadMetersFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return;
    final content = String.fromCharCodes(result.files.single.bytes!);
    try {
      final meters = parseMeters(content);
      setState(() {
        _meters = meters;
        _radioIndex.clear();
        for (int i = 0; i < meters.length; i++) {
          if (meters[i].radioNum != null) _radioIndex[meters[i].radioNum!] = i;
        }
      });
      final keys = meters.where((m) => m.hasKey).length;
      final noInst = meters.where((m) => !m.isInstalled).length;
      _addLog('Loaded ${meters.length} meters '
          '($keys with key, $noInst not installed)  ← ${result.files.single.name}');
      // Retry frames that arrived before a key was available
      _retryPendingNoKey();
    } catch (e) {
      _showError('Load error', e.toString());
    }
  }

  void _retryPendingNoKey() {
    if (_pendingNoKey.isEmpty) return;
    int retried = 0;
    for (final radio in List.of(_pendingNoKey.keys)) {
      final idx = _radioIndex[radio];
      if (idx == null) continue;
      final meter = _meters[idx];
      if (!meter.hasKey) continue; // still no key
      for (final raw in _pendingNoKey[radio]!) {
        _handleFrame(raw);
        retried++;
      }
      _pendingNoKey.remove(radio);
    }
    if (retried > 0) _addLog('Retried $retried buffered frame(s) for meters that now have keys');
  }

  Future<void> _downloadTemplate() async {
    final data = await rootBundle.load('assets/meters_template.csv');
    final bytes = data.buffer.asUint8List();
    final path = await saveCsvFile(String.fromCharCodes(bytes), 'meters_template.csv');
    await Share.shareXFiles(
      [XFile(path, mimeType: 'text/csv')],
      subject: 'meters_template.csv',
    );
  }

  // ── Connect / Disconnect ───────────────────────────────────────────────────
  Future<void> _toggleConnect() async {
    if (_connected) {
      await SerialService.instance.disconnect();
      _addLog('Disconnected.');
    } else {
      if (_selectedDevice == null) {
        _showError('No device', 'Select a USB device first.');
        return;
      }
      _addLog('Connecting to ${_selectedDevice!.label} @ $_baud baud…');
      await SerialService.instance.connect(_selectedDevice!, _baud);
    }
  }

  // ── Raw frame buffer ───────────────────────────────────────────────────────
  void _addRawFrame(Uint8List raw, {int? radioNum, String reason = 'ok'}) {
    if (_rawFrames.length >= 2000) _rawFrames.removeAt(0); // cap at 2000
    _rawFrames.add((
      ts:       DateTime.now(),
      radioNum: radioNum,
      reason:   reason,
      hex:      raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase(),
    ));
  }

  // ── Frame handling ─────────────────────────────────────────────────────────
  void _handleFrame(Uint8List raw) {
    final parsed = parseRawFrame(raw);
    if (parsed == null) {
      _addRawFrame(raw, reason: 'parse_error');
      return;
    }

    final radio = parsed.radioNum;
    final bd    = parsed.blockData;
    _addRawFrame(raw, radioNum: radio);

    final idx   = _radioIndex[radio];

    // Meter not in list – route to Unknown tab handler
    if (idx == null) {
      _handleUnknownFrame(parsed);
      return;
    }

    final meter = _meters[idx];

    // ── Techem unencrypted (CI=A2 water, CI=A0 HCA) ───────────────────────
    if (isTechFrame(parsed.mBytes) && bd.isNotEmpty &&
        (bd[0] == 0xA2 || bd[0] == 0xA0)) {
      _applyTechResult(meter, parsed, radio);
      return;
    }

    // ── Apator 162 TPL-direct (CI=0x7A) ──────────────────────────────────────
    if (isApaFrame(parsed.mBytes) && bd.isNotEmpty && bd[0] == 0x7A && bd.length >= 5) {
      _handleApa162Frame(meter, parsed, radio);
      return;
    }

    // ── Apator AES-128-CBC (ELL + TPL mode 5) ─────────────────────────────
    final key = meter.aesKey;
    if (key == null) {
      // Save raw frame for retry when key becomes available
      _pendingNoKey.putIfAbsent(radio, () => []).add(raw);
      _addLog('ID=$radio → no key (frame saved for retry)');
      setState(() => meter.status = MeterStatus.noKey);
      return;
    }

    if (bd.isEmpty || bd[0] != 0x8C || bd.length < 8 || bd[3] != 0x7A) {
      _addLog('ID=$radio → unsupported CI=0x${bd.isNotEmpty ? bd[0].toRadixString(16) : "?"}');
      setState(() => meter.status = MeterStatus.failed);
      return;
    }

    final tplAcc  = bd[4];
    final tplCfg  = (bd[7] << 8) | bd[6];
    final secMode = (tplCfg >> 8) & 0x1F;
    final nEnc    = (tplCfg >> 4) & 0x0F;

    if (secMode != 5) {
      _addLog('ID=$radio → unsupported security mode $secMode');
      setState(() => meter.status = MeterStatus.failed);
      return;
    }

    final encEnd = nEnc > 0 ? math.min(8 + nEnc * 16, bd.length) : bd.length;
    final enc = bd.sublist(8, encEnd);
    final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
    if (encAligned.length < 16) {
      setState(() => meter.status = MeterStatus.failed);
      return;
    }

    final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
    final pt = decryptCbc(key, iv, Uint8List.fromList(encAligned));

    if (pt == null || pt[0] != 0x2F) {
      _addLog('ID=$radio → decrypt failed');
      setState(() => meter.status = MeterStatus.failed);
      return;
    }

    final oms    = parseOmsPayload(Uint8List.fromList(pt));
    final alarms = decodeAlarms(oms.faultsWord);
    final hist   = buildHistoryDates(oms.history, oms.timestamp);
    final status = (oms.faultsWord != null && oms.faultsWord != 0)
        ? MeterStatus.alarm
        : MeterStatus.ok;

    final volStr = oms.volumeM3?.toStringAsFixed(3) ?? 'N/A';
    final tsStr  = oms.timestamp != null
        ? '${oms.timestamp!.year}-'
          '${oms.timestamp!.month.toString().padLeft(2, '0')}-'
          '${oms.timestamp!.day.toString().padLeft(2, '0')} '
          '${oms.timestamp!.hour.toString().padLeft(2, '0')}:'
          '${oms.timestamp!.minute.toString().padLeft(2, '0')}'
        : 'N/A';
    final flt = alarms.where((a) => a != 'OK').join(', ');
    _addLog('ID=$radio  ${status.label}  vol=$volStr m³  $tsStr'
        '${flt.isNotEmpty ? "  ⚠ $flt" : ""}');

    setState(() {
      meter.status   = status;
      meter.volumeM3 = oms.volumeM3;
      meter.readAt   = DateTime.now();
      meter.alarms   = alarms;
      meter.history  = hist
          .map((h) => HistoryEntry(date: h.date, volumeM3: h.volumeM3))
          .toList();
    });
  }

  // ── Apator 162 CI=0x7A handler (known meter) ─────────────────────────────
  void _handleApa162Frame(Meter meter, ParsedFrame parsed, int radio) {
    final bd = parsed.blockData;
    // bd[0]=CI(0x7A), bd[1]=TPL_ACC, bd[2]=Status, bd[3-4]=Config LE
    final tplAcc  = bd[1];
    final tplCfg  = (bd[4] << 8) | bd[3];
    final secMode = (tplCfg >> 8) & 0x1F;
    final nEnc    = (tplCfg >> 4) & 0x0F;

    if (secMode != 5) {
      _addLog('ID=$radio (A162) → unsupported security mode $secMode');
      setState(() => meter.status = MeterStatus.failed);
      return;
    }

    final encEnd = nEnc > 0 ? math.min(5 + nEnc * 16, bd.length) : bd.length;
    final enc = bd.sublist(5, encEnd);
    final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
    if (encAligned.length < 16) {
      setState(() => meter.status = MeterStatus.failed);
      return;
    }

    final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);

    // Try meter's known key first, then fall back to zero key
    final meterKey = meter.aesKey;
    Uint8List? pt;
    bool usedZeroKey = false;
    if (meterKey != null) {
      pt = decryptCbc(meterKey, iv, Uint8List.fromList(encAligned));
    }
    if (pt == null || pt[0] != 0x2F) {
      pt = decryptCbc(List<int>.filled(16, 0), iv, Uint8List.fromList(encAligned));
      usedZeroKey = true;
    }

    if (pt == null || pt[0] != 0x2F) {
      _addLog('ID=$radio (A162) → decrypt failed');
      setState(() => meter.status = MeterStatus.failed);
      return;
    }

    double? volumeM3;
    List<String> alarms = ['OK'];
    List<HistoryEntry> hist = [];

    if (isApa162Payload(Uint8List.fromList(pt))) {
      final r = parseApa162Payload(Uint8List.fromList(pt));
      volumeM3 = r.totalM3;
      // Convert Apa162 monthly offsets to approximate end-of-month dates
      final now = DateTime.now();
      hist = r.history.map((h) {
        int m = now.month - h.month;
        int y = now.year;
        if (m <= 0) { m += 12; y -= 1; }
        final date = DateTime(y, m + 1, 0, 23, 59); // last day of that month
        return HistoryEntry(date: date, volumeM3: h.volumeM3);
      }).toList();
    } else {
      final oms = parseOmsPayload(Uint8List.fromList(pt));
      volumeM3 = oms.volumeM3;
      alarms   = decodeAlarms(oms.faultsWord);
      hist     = buildHistoryDates(oms.history, oms.timestamp)
          .map((h) => HistoryEntry(date: h.date, volumeM3: h.volumeM3))
          .toList();
    }

    final keyTag = usedZeroKey ? ' [zero-key]' : '';
    _addLog('ID=$radio (A162)$keyTag  vol=${volumeM3?.toStringAsFixed(3)} m³'
        '${hist.isNotEmpty ? "  hist=${hist.length}" : ""}');

    setState(() {
      meter.status   = MeterStatus.ok;
      meter.volumeM3 = volumeM3;
      meter.readAt   = DateTime.now();
      meter.alarms   = alarms;
      meter.history  = hist;
    });
  }

  // ── Apply Techem result to a known Meter entry ─────────────────────────────
  void _applyTechResult(Meter meter, ParsedFrame parsed, int radio) {
    final bd = parsed.blockData;
    if (bd[0] == 0xA2) {
      final r = parseTechWater(bd);
      if (r == null) {
        _addLog('ID=$radio → Techem water parse failed');
        setState(() => meter.status = MeterStatus.failed);
        return;
      }
      _addLog('ID=$radio  Techem water  total=${r.totalM3.toStringAsFixed(3)} m³'
          '  (prev=${r.prevM3} @ ${_fmtDate(r.prevDate)}'
          '  curr=${r.currM3} @ ${_fmtDate(r.currDate)})');
      setState(() {
        meter.status   = MeterStatus.ok;
        meter.volumeM3 = r.totalM3;
        meter.readAt   = DateTime.now();
        meter.alarms   = ['OK'];
      });
    } else {
      // CI=A0 HCA
      final r = parseTechHca(bd, dllVersion: parsed.sw);
      if (r == null) {
        _addLog('ID=$radio → Techem HCA parse failed');
        setState(() => meter.status = MeterStatus.failed);
        return;
      }
      _addLog('ID=$radio  Techem HCA  prev=${r.prevHca} curr=${r.currHca}'
          '  T_room=${r.tempRoomC?.toStringAsFixed(1)}°C'
          '  T_rad=${r.tempRadiatorC?.toStringAsFixed(1)}°C');
      setState(() {
        meter.status = MeterStatus.ok;
        meter.readAt = DateTime.now();
        meter.alarms = ['OK'];
      });
    }
  }

  // ── Unknown frame handler ─────────────────────────────────────────────────
  void _handleUnknownFrame(ParsedFrame parsed) {
    final radio = parsed.radioNum;
    final bd    = parsed.blockData;
    if (bd.isEmpty) return;

    UnknownMeter meter;

    // ── Techem unencrypted (CI=A2 water / CI=A0 HCA) ──────────────────────
    if (isTechFrame(parsed.mBytes) && (bd[0] == 0xA2 || bd[0] == 0xA0)) {
      if (bd[0] == 0xA2) {
        final r = parseTechWater(bd);
        final isWarm = parsed.aBytes.length >= 6 && parsed.aBytes[5] == 0x72;
        if (r != null) {
          _addLog('ID=$radio  ${isWarm ? "♨ Techem warm" : "💧 Techem cold"}'
              '  total=${r.totalM3.toStringAsFixed(3)} m³'
              '  (prev=${r.prevM3} curr=${r.currM3})');
          meter = UnknownMeter(
            radioNum:  radio,
            kind:      UnknownMeterKind.techWater,
            totalM3:   r.totalM3,
            prevM3:    r.prevM3,
            currM3:    r.currM3,
            prevDate:  r.prevDate,
            currDate:  r.currDate,
            isWarmWater: isWarm,
            readAt:    DateTime.now(),
          );
        } else {
          _addLog('ID=$radio → Techem water parse failed');
          meter = UnknownMeter(radioNum: radio, kind: UnknownMeterKind.zeroKeyFail, readAt: DateTime.now());
        }
      } else {
        // CI=A0 HCA
        final r = parseTechHca(bd, dllVersion: parsed.sw);
        if (r != null) {
          _addLog('ID=$radio  🌡 Techem HCA'
              '  prev=${r.prevHca}  curr=${r.currHca}'
              '  T=${r.tempRoomC?.toStringAsFixed(1)}°C');
          meter = UnknownMeter(
            radioNum:      radio,
            kind:          UnknownMeterKind.techHca,
            prevHca:       r.prevHca,
            currHca:       r.currHca,
            prevDate:      r.prevDate,
            currDate:      r.currDate,
            tempRoomC:     r.tempRoomC,
            tempRadiatorC: r.tempRadiatorC,
            readAt:        DateTime.now(),
          );
        } else {
          _addLog('ID=$radio → Techem HCA parse failed');
          meter = UnknownMeter(radioNum: radio, kind: UnknownMeterKind.zeroKeyFail, readAt: DateTime.now());
        }
      }
    }
    // ── Apator 162 TPL-direct (CI=0x7A) – try zero key ───────────────────────
    else if (isApaFrame(parsed.mBytes) && bd[0] == 0x7A && bd.length >= 5) {
      final tplAcc  = bd[1];
      final tplCfg  = (bd[4] << 8) | bd[3];
      final secMode = (tplCfg >> 8) & 0x1F;
      final nEnc    = (tplCfg >> 4) & 0x0F;

      double? volumeM3;
      List<HistoryEntry> hist = [];
      bool decrypted = false;

      if (secMode == 5) {
        final encEnd2 = nEnc > 0 ? math.min(5 + nEnc * 16, bd.length) : bd.length;
        final enc = bd.sublist(5, encEnd2);
        final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
        if (encAligned.length >= 16) {
          final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
          final pt = decryptCbc(List<int>.filled(16, 0), iv, Uint8List.fromList(encAligned));
          if (pt != null && pt[0] == 0x2F) {
            decrypted = true;
            if (isApa162Payload(Uint8List.fromList(pt))) {
              final r = parseApa162Payload(Uint8List.fromList(pt));
              volumeM3 = r.totalM3;
              final now = DateTime.now();
              hist = r.history.map((h) {
                int m = now.month - h.month;
                int y = now.year;
                if (m <= 0) { m += 12; y -= 1; }
                return HistoryEntry(date: DateTime(y, m + 1, 0, 23, 59), volumeM3: h.volumeM3);
              }).toList();
            } else {
              final oms = parseOmsPayload(Uint8List.fromList(pt));
              volumeM3 = oms.volumeM3;
              hist = buildHistoryDates(oms.history, oms.timestamp)
                  .map((h) => HistoryEntry(date: h.date, volumeM3: h.volumeM3))
                  .toList();
            }
          }
        }
      }
      _addLog('ID=$radio (A162) → ${decrypted ? "✅ zero-key vol=${volumeM3?.toStringAsFixed(3)} m³  hist=${hist.length}" : "❌ decrypt failed"}');
      meter = UnknownMeter(
        radioNum: radio,
        kind:     decrypted ? UnknownMeterKind.zeroKeyOk : UnknownMeterKind.zeroKeyFail,
        totalM3:  volumeM3,
        history:  hist,
        readAt:   DateTime.now(),
      );
    }
    // ── Apator-style encrypted – try zero key ──────────────────────────────
    else if (bd.length >= 8 && bd[0] == 0x8C && bd[3] == 0x7A) {
      final tplAcc  = bd[4];
      final tplCfg  = (bd[7] << 8) | bd[6];
      final secMode = (tplCfg >> 8) & 0x1F;
      final nEnc    = (tplCfg >> 4) & 0x0F;

      double? volumeM3;
      DateTime? timestamp;
      List<String> alarms = [];
      List<HistoryEntry> hist = [];
      bool decrypted = false;

      if (secMode == 5) {
        final encEnd3 = nEnc > 0 ? math.min(8 + nEnc * 16, bd.length) : bd.length;
        final enc = bd.sublist(8, encEnd3);
        final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
        if (encAligned.length >= 16) {
          final zeroKey = List<int>.filled(16, 0);
          final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
          final pt = decryptCbc(zeroKey, iv, Uint8List.fromList(encAligned));
          if (pt != null && pt[0] == 0x2F) {
            decrypted = true;
            final oms = parseOmsPayload(Uint8List.fromList(pt));
            volumeM3  = oms.volumeM3;
            timestamp = oms.timestamp;
            alarms    = decodeAlarms(oms.faultsWord);
            hist = buildHistoryDates(oms.history, oms.timestamp)
                .map((h) => HistoryEntry(date: h.date, volumeM3: h.volumeM3))
                .toList();
          }
        }
      }
      _addLog('ID=$radio → ${decrypted ? "✅ zero-key vol=${volumeM3?.toStringAsFixed(3)} m³  hist=${hist.length}" : "❌ unknown encrypted"}');
      meter = UnknownMeter(
        radioNum: radio,
        kind:     decrypted ? UnknownMeterKind.zeroKeyOk : UnknownMeterKind.zeroKeyFail,
        totalM3:  volumeM3,
        currDate: timestamp,
        alarms:   alarms,
        history:  hist,
        readAt:   DateTime.now(),
      );
    }
    // ── Completely unknown CI ──────────────────────────────────────────────
    else {
      _addLog('ID=$radio → unknown CI=0x${bd[0].toRadixString(16)}');
      meter = UnknownMeter(radioNum: radio, kind: UnknownMeterKind.zeroKeyFail, readAt: DateTime.now());
    }

    setState(() {
      final existingIdx = _unknownIndex[radio];
      if (existingIdx != null) {
        final existing = _unknown[existingIdx];
        existing.kind          = meter.kind;
        existing.totalM3       = meter.totalM3 ?? existing.totalM3;
        existing.prevM3        = meter.prevM3  ?? existing.prevM3;
        existing.currM3        = meter.currM3  ?? existing.currM3;
        existing.prevDate      = meter.prevDate ?? existing.prevDate;
        existing.currDate      = meter.currDate ?? existing.currDate;
        existing.alarms        = meter.alarms.isNotEmpty ? meter.alarms : existing.alarms;
        existing.prevHca       = meter.prevHca ?? existing.prevHca;
        existing.currHca       = meter.currHca ?? existing.currHca;
        existing.tempRoomC     = meter.tempRoomC ?? existing.tempRoomC;
        existing.tempRadiatorC = meter.tempRadiatorC ?? existing.tempRadiatorC;
        existing.isWarmWater   = meter.isWarmWater;
        existing.readAt        = DateTime.now();
        existing.frameCount++;
      } else {
        _unknownIndex[radio] = _unknown.length;
        _unknown.add(meter);
      }
    });
  }

  // ── Log ───────────────────────────────────────────────────────────────────
  void _addLog(String msg) {
    final now = DateTime.now();
    final ts  = '${now.hour.toString().padLeft(2, '0')}:'
                '${now.minute.toString().padLeft(2, '0')}:'
                '${now.second.toString().padLeft(2, '0')}';
    setState(() => _log.add('$ts  $msg'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollLog.hasClients) {
        _scrollLog.jumpTo(_scrollLog.position.maxScrollExtent);
      }
    });
  }

  // ── Export ────────────────────────────────────────────────────────────────
  Future<void> _export() async {
    if (_meters.isEmpty) { _showError('Nothing to export', 'Load a meters file first.'); return; }
    final csv  = exportToCsv(_meters);
    final path = await saveCsvFile(csv, 'wmbus_results.csv');
    await Share.shareXFiles(
      [XFile(path, mimeType: 'text/csv')],
      text: 'W-MBus reading results',
    );
  }

  Future<void> _exportUnknown() async {
    if (_unknown.isEmpty) { _showError('Nothing to export', 'No unknown meters received yet.'); return; }
    final csv  = exportUnknownToCsv(_unknown);
    final path = await saveCsvFile(csv, 'wmbus_unknown.csv');
    await Share.shareXFiles(
      [XFile(path, mimeType: 'text/csv')],
      text: 'W-MBus unknown meters',
    );
  }

  Future<void> _exportRawFrames() async {
    if (_rawFrames.isEmpty) { _showError('Nothing to export', 'No frames received yet.'); return; }
    final csv  = exportRawFramesToCsv(_rawFrames);
    final path = await saveCsvFile(csv, 'wmbus_raw_frames.csv');
    await Share.shareXFiles(
      [XFile(path, mimeType: 'text/csv')],
      text: 'W-MBus raw frames',
    );
  }

  // ── Reset all ─────────────────────────────────────────────────────────────
  void _resetAll() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset all'),
        content: const Text('Reset all meter statuses to Pending?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              setState(() {
        for (final m in _meters) { m.reset(); }
      });
              Navigator.pop(context);
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  void _showError(String title, String msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }

  List<Meter> get _filteredMeters => _filterStatus == null
      ? _meters
      : _meters.where((m) => m.status == _filterStatus).toList();

  // ── Summary counts ────────────────────────────────────────────────────────
  int get _cntOk      => _meters.where((m) => m.status == MeterStatus.ok).length;
  int get _cntAlarm   => _meters.where((m) => m.status == MeterStatus.alarm).length;
  int get _cntPending => _meters.where((m) => m.status == MeterStatus.pending).length;

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FLUO', style: TextStyle(fontSize: 16)),
        backgroundColor: Colors.blueGrey.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh USB devices',
              onPressed: () => SerialService.instance.refreshDevices()),
          PopupMenuButton<String>(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Export',
            onSelected: (v) {
              if (v == 'meters')  _export();
              if (v == 'unknown') _exportUnknown();
              if (v == 'raw')     _exportRawFrames();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'meters',  child: Text('Export meters CSV')),
              PopupMenuItem(value: 'unknown', child: Text('Export unknown meters CSV')),
              PopupMenuItem(value: 'raw',     child: Text('Export raw frames CSV')),
            ],
          ),
          IconButton(icon: const Icon(Icons.restart_alt), tooltip: 'Reset all',
              onPressed: _resetAll),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          indicatorColor: Colors.white,
          tabs: [
            const Tab(text: 'Meters'),
            Tab(text: 'Unknown (${_unknown.length})'),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildToolbar(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                Column(children: [
                  _buildSummaryBar(),
                  Expanded(child: _buildMeterList()),
                ]),
                _buildUnknownTab(),
              ],
            ),
          ),
          _buildLogPanel(),
        ],
      ),
    );
  }

  // ── Toolbar ───────────────────────────────────────────────────────────────
  Widget _buildToolbar() {
    return Container(
      color: Colors.blueGrey.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          // Row 1: device selector + baud + connect
          Row(
            children: [
              const Text('Device:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              Expanded(
                child: DropdownButton<SerialDevice>(
                  isExpanded: true,
                  value: _selectedDevice,
                  hint: const Text('Select USB device', style: TextStyle(fontSize: 12)),
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                  items: _devices.map((d) => DropdownMenuItem(
                    value: d,
                    child: Text(d.label, overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: _connected ? null : (d) => setState(() => _selectedDevice = d),
                ),
              ),
              const SizedBox(width: 6),
              const Text('Baud:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              DropdownButton<int>(
                value: _baud,
                style: const TextStyle(fontSize: 12, color: Colors.black87),
                items: [9600, 19200, 38400, 57600, 115200].map((b) => DropdownMenuItem(
                  value: b, child: Text('$b'),
                )).toList(),
                onChanged: _connected ? null : (b) => setState(() => _baud = b!),
              ),
              const SizedBox(width: 6),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _connected ? Colors.red.shade700 : Colors.green.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                onPressed: _toggleConnect,
                child: Text(_connected ? 'Disconnect' : 'Connect'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Row 2: meters file
          Row(
            children: [
              const Text('Meters file:', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _meters.isEmpty ? 'No file loaded' : '${_meters.length} meters loaded',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.folder_open, size: 14),
                label: const Text('Open', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                onPressed: _loadMetersFile,
              ),
              const SizedBox(width: 6),
              ElevatedButton.icon(
                icon: const Icon(Icons.download, size: 14),
                label: const Text('Template', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                onPressed: _downloadTemplate,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Summary bar ───────────────────────────────────────────────────────────
  Widget _buildSummaryBar() {
    if (_meters.isEmpty) return const SizedBox.shrink();
    return Container(
      color: Colors.blueGrey.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Text('Total: ${_meters.length}', style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 12),
          _chip('✅ ${_cntOk}', const Color(0xFFC8F5C8)),
          const SizedBox(width: 6),
          _chip('⚠️ ${_cntAlarm}', const Color(0xFFFFF0A0)),
          const SizedBox(width: 6),
          _chip('⏳ ${_cntPending}', const Color(0xFFF5F5F5)),
          const Spacer(),
          const Text('Filter: ', style: TextStyle(fontSize: 11)),
          DropdownButton<MeterStatus?>(
            value: _filterStatus,
            style: const TextStyle(fontSize: 11, color: Colors.black87),
            items: [
              const DropdownMenuItem(value: null, child: Text('All')),
              ...MeterStatus.values.map((s) => DropdownMenuItem(value: s, child: Text(s.label))),
            ],
            onChanged: (s) => setState(() => _filterStatus = s),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
    child: Text(text, style: const TextStyle(fontSize: 11)),
  );

  // ── Meter list ────────────────────────────────────────────────────────────
  Widget _buildMeterList() {
    final meters = _filteredMeters;
    if (meters.isEmpty) {
      return Center(
        child: Text(
          _meters.isEmpty ? 'Open a meters CSV file to begin.' : 'No meters match the filter.',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.separated(
      controller: _scrollMeters,
      itemCount: meters.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final meter = meters[i];
        final globalIdx = _meters.indexOf(meter) + 1;
        return MeterTile(
          index: globalIdx,
          meter: meter,
          pendingCount: meter.radioNum != null
              ? (_pendingNoKey[meter.radioNum]?.length ?? 0)
              : 0,
          onConfirm: () => setState(() {
            meter.status = MeterStatus.ok;
            meter.readAt ??= DateTime.now();
          }),
          onReset: () => setState(() => meter.reset()),
          onEnterKey: meter.radioNum == null ? null : (keyHex) {
            final key = List.generate(
              16, (i) => int.parse(keyHex.substring(i * 2, i * 2 + 2), radix: 16));
            setState(() {
              // Inject key directly into meter object
              final idx2 = _radioIndex[meter.radioNum];
              if (idx2 != null) {
                final m = _meters[idx2];
                // Replace meter with key
                _meters[idx2] = Meter(
                  building:  m.building,
                  staircase: m.staircase,
                  apartment: m.apartment,
                  serial:    m.serial,
                  radioNum:  m.radioNum,
                  aesKey:    key,
                  status:    MeterStatus.pending,
                );
                _radioIndex[m.radioNum!] = idx2;
              }
            });
            _retryPendingNoKey();
            _addLog('ID=${meter.radioNum} → key entered manually, retrying buffered frames');
          },
        );
      },
    );
  }

  // ── Unknown meters tab ────────────────────────────────────────────────────
  Widget _buildUnknownTab() {
    if (_unknown.isEmpty) {
      return const Center(
        child: Text(
          'No unknown meters received yet.\n'
          'Frames from meters not in the CSV list will appear here.\n'
          'Decryption is attempted with an all-zero AES key.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    final filtered = _unknownSearch.isEmpty
        ? _unknown
        : _unknown.where((m) => m.radioNum.toString().contains(_unknownSearch)).toList();

    return Column(
      children: [
        Container(
          color: Colors.blueGrey.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            children: [
              Text('${filtered.length} / ${_unknown.length} unknown meter(s)',
                  style: const TextStyle(fontSize: 12)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.delete_sweep, size: 14),
                label: const Text('Clear', style: TextStyle(fontSize: 11)),
                onPressed: () => setState(() {
                  _unknown.clear();
                  _unknownIndex.clear();
                }),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: TextField(
            controller: _unknownSearchCtrl,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search by radio ID…',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _unknownSearch.isEmpty ? null : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => setState(() {
                  _unknownSearchCtrl.clear();
                  _unknownSearch = '';
                }),
              ),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
            keyboardType: TextInputType.number,
            onChanged: (v) => setState(() => _unknownSearch = v.trim()),
          ),
        ),
        Expanded(
          child: ListView.separated(
            controller: _scrollUnknown,
            itemCount: filtered.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => _buildUnknownTile(filtered[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildUnknownTile(UnknownMeter m) {
    final Color bg;
    final Color fg;
    switch (m.kind) {
      case UnknownMeterKind.techWater:
        bg = const Color(0xFFD0EAF5);
        fg = const Color(0xFF004070);
      case UnknownMeterKind.techHca:
        bg = const Color(0xFFF5E8D0);
        fg = const Color(0xFF704000);
      case UnknownMeterKind.zeroKeyOk:
        bg = const Color(0xFFC8F5C8);
        fg = const Color(0xFF006600);
      case UnknownMeterKind.zeroKeyFail:
        bg = const Color(0xFFFFD0D0);
        fg = const Color(0xFF880000);
    }

    final alarmStr = m.alarms.where((a) => a != 'OK').join(', ');

    List<Widget> subtitleLines = [
      Text('Frames: ${m.frameCount}  Last: ${_fmtDt(m.readAt)}',
          style: TextStyle(fontSize: 11, color: fg)),
    ];

    if (m.kind == UnknownMeterKind.techWater) {
      subtitleLines.add(Text(
        'Total: ${m.totalM3?.toStringAsFixed(3)} m³'
        '  (prev: ${m.prevM3?.toStringAsFixed(1)} @ ${_fmtDate(m.prevDate)}'
        '  curr: ${m.currM3?.toStringAsFixed(1)} @ ${_fmtDate(m.currDate)})',
        style: TextStyle(fontSize: 11, color: fg),
      ));
    } else if (m.kind == UnknownMeterKind.techHca) {
      subtitleLines.add(Text(
        'HCA: prev=${m.prevHca}  curr=${m.currHca}'
        '  T_room=${m.tempRoomC?.toStringAsFixed(1)}°C'
        '  T_rad=${m.tempRadiatorC?.toStringAsFixed(1)}°C',
        style: TextStyle(fontSize: 11, color: fg),
      ));
      subtitleLines.add(Text(
        'prev @ ${_fmtDate(m.prevDate)}  curr @ ${_fmtDate(m.currDate)}',
        style: TextStyle(fontSize: 11, color: fg),
      ));
    } else if (m.kind == UnknownMeterKind.zeroKeyOk) {
      subtitleLines.add(Text(
        'Vol: ${m.totalM3?.toStringAsFixed(3)} m³'
        '  @ ${_fmtDate(m.currDate)}',
        style: TextStyle(fontSize: 11, color: fg),
      ));
      if (alarmStr.isNotEmpty) {
        subtitleLines.add(Text('⚠ $alarmStr', style: TextStyle(fontSize: 11, color: fg)));
      }
    }

    return Container(
      color: bg,
      child: ListTile(
        dense: true,
        onTap: () => _showUnknownDetail(context, m),
        leading: Icon(
          m.kind == UnknownMeterKind.techHca ? Icons.thermostat_outlined : Icons.water_drop_outlined,
          color: fg,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text('ID: ${m.radioNum}',
                  style: TextStyle(fontWeight: FontWeight.w600, color: fg, fontSize: 13)),
            ),
            Text(m.kindLabel, style: TextStyle(fontSize: 12, color: fg)),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: subtitleLines,
        ),
      ),
    );
  }

  void _showUnknownDetail(BuildContext context, UnknownMeter m) {
    final alarmList = m.alarms.where((a) => a != 'OK').toList();

    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ]),
    );

    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(title, style: TextStyle(
        fontSize: 12, fontWeight: FontWeight.bold,
        color: Colors.blueGrey.shade700, letterSpacing: 0.5,
      )),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Center(child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)),
            )),

            Text('ID: ${m.radioNum}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(m.kindLabel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Divider(height: 20),

            row('Frames received', '${m.frameCount}'),
            row('Last seen', _fmtDate(m.readAt)),

            if (m.kind == UnknownMeterKind.techWater || m.kind == UnknownMeterKind.zeroKeyOk) ...[
              section('Reading'),
              if (m.totalM3 != null) row('Total volume', '${m.totalM3!.toStringAsFixed(3)} m³'),
              if (m.prevM3 != null)  row('Previous period', '${m.prevM3!.toStringAsFixed(3)} m³  @ ${_fmtDate(m.prevDate)}'),
              if (m.currM3 != null)  row('Current period',  '${m.currM3!.toStringAsFixed(3)} m³  @ ${_fmtDate(m.currDate)}'),
            ],

            if (m.kind == UnknownMeterKind.techHca) ...[
              section('Heat cost allocator'),
              if (m.prevHca != null) row('Previous HCA', '${m.prevHca}  @ ${_fmtDate(m.prevDate)}'),
              if (m.currHca != null) row('Current HCA',  '${m.currHca}  @ ${_fmtDate(m.currDate)}'),
              if (m.tempRoomC != null)     row('Room temp',     '${m.tempRoomC!.toStringAsFixed(1)} °C'),
              if (m.tempRadiatorC != null) row('Radiator temp', '${m.tempRadiatorC!.toStringAsFixed(1)} °C'),
            ],

            if (alarmList.isNotEmpty) ...[
              section('Alarms'),
              ...alarmList.map((a) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                  const SizedBox(width: 6),
                  Text(a, style: const TextStyle(fontSize: 13)),
                ]),
              )),
            ],

            if (m.history.isNotEmpty) ...[
              section('History'),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: const [
                  SizedBox(width: 130, child: Text('Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey))),
                  Text('Volume (m³)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey)),
                ]),
              ),
              ...m.history.map((h) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  SizedBox(width: 130, child: Text(
                    h.date != null ? _fmtDate(h.date) : '—',
                    style: const TextStyle(fontSize: 13),
                  )),
                  Text(h.volumeM3.toStringAsFixed(3),
                      style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
                ]),
              )),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtDate(DateTime? dt) {
    if (dt == null) return '—';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  String _fmtDt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  // ── Log panel ─────────────────────────────────────────────────────────────
  Widget _buildLogPanel() {
    return Container(
      height: 150,
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              children: [
                const Text('Log', style: TextStyle(color: Colors.grey, fontSize: 11)),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() => _log.clear()),
                  child: const Text('Clear', style: TextStyle(fontSize: 10, color: Colors.grey)),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollLog,
              itemCount: _log.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                child: Text(
                  _log[i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFFCCCCCC)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
