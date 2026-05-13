// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

import '../models/meter.dart';
import '../services/apator_bt_impl.dart';
import '../models/apator_profile.dart' show registerById, kAtWmbus16Registers;
import '../services/apator_bt_service.dart';
import '../services/csv_service.dart';
import '../services/serial_service.dart';
import '../services/wmbus_decoder.dart';
import '../widgets/meter_tile.dart';
import 'device_config_screen.dart';
import 'profile_screen.dart';

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

  // Bluetooth listening
  final _bt = ApatorBtServiceImpl.instance;
  bool _btListening = false;
  StreamSubscription<Uint8List>? _btFrameSub;
  StreamSubscription<ApatorBtState>? _btStateSub;

  // Sniff mode (Adeunis ARF8020AA listening config).
  // Cmd format: FF×8 FD +++ to enter, then 2-byte <KEY><VALUE> uppercase.
  // ARF8020AA fw 3.02 supports only T/S/R (one-way modes). No T2 bidirectional.
  bool _sniffMode = false;
  int _sniffFrameCount = 0;
  AdeunisLinkMode _sniffRadioMode = AdeunisLinkMode.t1; // default: T-mode
  AdeunisRole _sniffRole = AdeunisRole.other;            // default: Other (RX)
  bool _sniffRawBytes = true; // log raw USB bytes during sniff (no parsing)
  StreamSubscription<Uint8List>? _sniffRawSub;

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

    // BT frame listening
    _btFrameSub = _bt.wmbusFrames.listen(_handleFrame);
    _btStateSub = _bt.connectionState.listen((s) {
      if (s == ApatorBtState.disconnected && _btListening) {
        setState(() => _btListening = false);
        _addLog('BT: rozlaczono');
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _frameSub?.cancel();
    _errorSub?.cancel();
    _stateSub?.cancel();
    _deviceSub?.cancel();
    _btFrameSub?.cancel();
    _btStateSub?.cancel();
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
      if (_sniffMode) {
        _sniffFrameCount++;
        final hex = raw.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
        _addLog('SNIFF[#$_sniffFrameCount] parse_err [${raw.length}B]: $hex');
      }
      return;
    }

    final radio = parsed.radioNum;
    final bd    = parsed.blockData;
    _addRawFrame(raw, radioNum: radio);

    if (_sniffMode) {
      _sniffFrameCount++;
      // raw[0]=SOF(0xFF), [1]=L, [2]=C, [3..4]=M, [5..10]=A(id+sw+hw), [11..]=payload(CI+data)
      final cField = raw.length > 2 ? raw[2] : 0;
      final ci = bd.isNotEmpty ? bd[0] : -1;
      final mHex = parsed.mBytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join('');
      final aHex = parsed.aBytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
      final bdHex = bd.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
      _addLog('SNIFF[#$_sniffFrameCount] L=${parsed.lField} '
          'C=0x${cField.toRadixString(16).padLeft(2, '0').toUpperCase()} '
          'M=$mHex A=[$aHex] ID=$radio '
          'CI=0x${ci >= 0 ? ci.toRadixString(16).padLeft(2, '0').toUpperCase() : "??"} '
          '[${bd.length}B]');
      _addLog('  PAYLOAD: $bdHex');
    }

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
      if (parsed.isRspUd) {
        _handleApa162RspUd(meter, parsed, radio);
      } else {
        _handleApa162Frame(meter, parsed, radio);
      }
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
  /// Handle Apa162 RSP-UD service response (slave→master answer to a register read).
  /// Format identical to broadcast (CI=0x7A, AES mode 5), but C-field is 0x08
  /// and tags inside payload represent register values (0xA3=RTC, 0xB0=periods, etc.).
  void _handleApa162RspUd(Meter? meter, ParsedFrame parsed, int radio) {
    final pt = _decryptApa162(parsed, meter);
    if (pt == null) {
      _addLog('ID=$radio (A162 RSP-UD) → decrypt failed');
      return;
    }
    if (!isApa162Payload(pt)) {
      _addLog('ID=$radio (A162 RSP-UD) → invalid plaintext (no 2F2F0F marker)');
      return;
    }
    final r = parseApa162Payload(pt);
    final tagsStr = r.rawTags.entries
        .map((e) => '0x${e.key.toRadixString(16).padLeft(2, '0').toUpperCase()}'
                    '=${e.value.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join('')}')
        .join('  ');
    _addLog('💡 ID=$radio (RSP-UD) tags: $tagsStr');
    // Save raw frame to buffer (already done in _handleFrame caller)
  }

  /// Try to decrypt an Apa162 frame (broadcast or RSP-UD). Returns plaintext bytes.
  Uint8List? _decryptApa162(ParsedFrame parsed, Meter? meter) {
    final bd = parsed.blockData;
    if (bd.length < 5) return null;
    final tplAcc  = bd[1];
    final tplCfg  = (bd[4] << 8) | bd[3];
    final secMode = (tplCfg >> 8) & 0x1F;
    final nEnc    = (tplCfg >> 4) & 0x0F;
    if (secMode != 5) return null;
    final encEnd = nEnc > 0 ? math.min(5 + nEnc * 16, bd.length) : bd.length;
    if (encEnd <= 5) return null;
    final enc = bd.sublist(5, encEnd);
    final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
    if (encAligned.length < 16) return null;
    final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
    // Try meter key first, then zero key
    Uint8List? pt;
    if (meter?.aesKey != null) {
      pt = decryptCbc(meter!.aesKey!, iv, Uint8List.fromList(encAligned));
    }
    if (pt == null || pt.isEmpty || pt[0] != 0x2F) {
      pt = decryptCbc(List<int>.filled(16, 0), iv, Uint8List.fromList(encAligned));
    }
    if (pt == null || pt.isEmpty || pt[0] != 0x2F) return null;
    return pt;
  }

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
      // RSP-UD service response — handle separately (no volume, log raw tags)
      if (parsed.isRspUd) {
        _handleApa162RspUd(null, parsed, radio);
        return;
      }
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

    // Set frame metadata on meter
    meter.sw = parsed.sw;
    meter.hw = parsed.hw;
    meter.isApator = isApaFrame(parsed.mBytes);

    setState(() {
      final existingIdx = _unknownIndex[radio];
      if (existingIdx != null) {
        final existing = _unknown[existingIdx];
        existing.kind          = meter.kind;
        existing.sw            = meter.sw;
        existing.hw            = meter.hw;
        existing.isApator      = meter.isApator;
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
    // Quiet mode: during a TX command, suppress per-meter log spam for radios
    // other than the target. Detect "ID=<number>" prefix in the message.
    final qr = _quietExceptRadio;
    if (qr != null) {
      final m = RegExp(r'ID=(\d+)').firstMatch(msg);
      if (m != null) {
        final id = int.tryParse(m.group(1)!);
        if (id != null && id != qr) return; // suppress
      }
    }
    final now = DateTime.now();
    final ts  = '${now.hour.toString().padLeft(2, '0')}:'
                '${now.minute.toString().padLeft(2, '0')}:'
                '${now.second.toString().padLeft(2, '0')}';
    final line = '$ts  $msg';
    debugPrint('[FLUO] $line'); // mirror to logcat for adb tailing
    setState(() => _log.add(line));
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

  // ── Sniff mode (Adeunis ARF8020AA listener) ───────────────────────────────
  Future<void> _toggleSniffMode() async {
    if (!_connected) {
      _showError('Brak polaczenia', 'Najpierw polacz dongle USB.');
      return;
    }
    final svc = SerialService.instance;
    if (_sniffMode) {
      // Disable: restore default M=T (T-mode listener) so broadcasts work
      _sniffRawSub?.cancel();
      _sniffRawSub = null;
      _addLog('SNIFF: restoring default M=T');
      await svc.enterCommandMode();
      await Future.delayed(const Duration(milliseconds: 100));
      await svc.setRadioMode(AdeunisLinkMode.t1);
      await Future.delayed(const Duration(milliseconds: 200));
      await svc.setRole(AdeunisRole.other);
      await Future.delayed(const Duration(milliseconds: 200));
      await svc.exitCommandMode();
      setState(() => _sniffMode = false);
      _addLog('=== SNIFF OFF (zlapano $_sniffFrameCount ramek) ===');
      return;
    }
    final modeName = '${_sniffRadioMode.label}/${_sniffRole.label}';
    _addLog('=== SNIFF ON: Adeunis $modeName ===');

    if (_sniffRawBytes) {
      _sniffRawSub = svc.rawBytes.listen((data) {
        final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
        _addLog('RAW[${data.length}B]: $hex');
      });
    }

    _addLog('SNIFF: enter command mode (FFx8 FD +++)');
    final inCmd = await svc.enterCommandMode();
    _addLog('SNIFF: command mode ack = ${inCmd ? "> (OK)" : "TIMEOUT"}');
    if (!inCmd) {
      _addLog('SNIFF: dongle nie odpowiedzial.');
      _sniffRawSub?.cancel();
      return;
    }

    _addLog('SNIFF: send "M${_sniffRadioMode.char}" (${_sniffRadioMode.label})');
    await svc.setRadioMode(_sniffRadioMode);
    await Future.delayed(const Duration(milliseconds: 200));

    _addLog('SNIFF: send "L${_sniffRole.char}" (role ${_sniffRole.label})');
    await svc.setRole(_sniffRole);
    await Future.delayed(const Duration(milliseconds: 200));

    _addLog('SNIFF: exit command mode');
    await svc.exitCommandMode();
    await Future.delayed(const Duration(milliseconds: 200));

    setState(() {
      _sniffMode = true;
      _sniffFrameCount = 0;
    });
  }

  /// Diagnostic probe — wejście w command mode + send `?` (help)
  /// żeby dongle wypisał listę dostępnych komend i ich składnię.
  Future<void> _probeAmber() async {
    if (!_connected) {
      _showError('Brak polaczenia', 'Najpierw polacz dongle USB.');
      return;
    }
    final svc = SerialService.instance;
    _addLog('=== ADEUNIS PROBE start ===');

    // Buffer all RAW bytes during probe + decode as ASCII for readability
    final probeRawSub = svc.rawBytes.listen((data) {
      final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
      final ascii = String.fromCharCodes(data.map((b) => (b >= 0x20 && b < 0x7F) ? b : 0x2E)); // '.' for non-print
      _addLog('RAW[${data.length}B]: $hex  | "$ascii"');
    });

    try {
      _addLog('PROBE: enter cmd mode (FFx8 FD +++)');
      final ack = await svc.enterCommandMode();
      _addLog('PROBE: cmd mode ack = ${ack ? "> (OK)" : "TIMEOUT"}');
      if (!ack) {
        _addLog('PROBE: brak odpowiedzi.');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 300));

      // Show current state
      _addLog('PROBE: send "?" (state)');
      await svc.sendCmdChar('?');
      await Future.delayed(const Duration(milliseconds: 1500));

      // Apply selected M and L (2-byte interactive: M<X>, L<X>, uppercase)
      _addLog('PROBE: send "M${_sniffRadioMode.char}" (set ${_sniffRadioMode.label})');
      await svc.setRadioMode(_sniffRadioMode);
      await Future.delayed(const Duration(milliseconds: 300));

      _addLog('PROBE: send "L${_sniffRole.char}" (role ${_sniffRole.label})');
      await svc.setRole(_sniffRole);
      await Future.delayed(const Duration(milliseconds: 300));

      _addLog('PROBE: send "?" (verify)');
      await svc.sendCmdChar('?');
      await Future.delayed(const Duration(milliseconds: 1500));

      _addLog('PROBE: exit cmd mode');
      await svc.exitCommandMode();
      await Future.delayed(const Duration(milliseconds: 500));

      _addLog('=== ADEUNIS PROBE end ===');
    } finally {
      probeRawSub.cancel();
    }
  }

  /// Snapshot raw frame buffer to a timestamped CSV (for later analysis).
  Future<void> _markAndSaveCapture() async {
    final now = DateTime.now();
    final marker = '=== MARK ${_fmtMarker(now)} (frames=${_rawFrames.length}) ===';
    _addLog(marker);
    // Always create file even if empty — user wants confirmation that save fired
    final csv = exportRawFramesToCsv(_rawFrames);
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    // Include current radio mode + role in filename for easier identification
    final modeTag = _sniffMode
        ? '_${_sniffRadioMode.label}_${_sniffRole.label}'
        : '';
    final path = await saveCsvFile(csv, 'capture_$stamp$modeTag.csv');
    _addLog('SNIFF: zapisano kapturę (${_rawFrames.length} ramek) -> $path');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Zapisano ${_rawFrames.length} ramek\n$path'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
    try {
      await Share.shareXFiles(
        [XFile(path, mimeType: 'text/csv')],
        text: 'OTA capture $stamp$modeTag',
      );
    } catch (e) {
      _addLog('SNIFF: share failed: $e (plik nadal zapisany)');
    }
  }

  String _fmtMarker(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}.'
      '${t.millisecond.toString().padLeft(3, '0')}';

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
          PopupMenuButton<String>(
            icon: const Icon(Icons.water_drop_outlined),
            tooltip: 'Apator',
            onSelected: (v) {
              if (v == 'profile') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                );
              } else if (v == 'config') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DeviceConfigScreen()),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'profile', child: Text('Przegladaj profil .inp')),
              PopupMenuItem(value: 'config', child: Text('Konfiguracja BT')),
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
          // Row 3: BT listening
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                _btListening ? Icons.bluetooth_connected : Icons.bluetooth,
                size: 16,
                color: _btListening ? Colors.blue : Colors.grey,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _btListening
                      ? 'BT nasluch aktywny'
                      : _bt.currentState == ApatorBtState.connected
                          ? 'BT polaczony (idle)'
                          : 'BT niepolaczony',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ),
              if (_bt.currentState == ApatorBtState.connected)
                ElevatedButton.icon(
                  icon: Icon(_btListening ? Icons.stop : Icons.play_arrow, size: 14),
                  label: Text(_btListening ? 'Stop' : 'Nasluch BT',
                      style: const TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _btListening ? Colors.orange : Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  onPressed: _toggleBtListening,
                ),
              if (_bt.currentState != ApatorBtState.connected)
                ElevatedButton.icon(
                  icon: const Icon(Icons.bluetooth_searching, size: 14),
                  label: const Text('Polacz BT', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DeviceConfigScreen()),
                  ),
                ),
            ],
          ),
          // Row 3b: Sniff status + mode/role selector
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                _sniffMode ? Icons.fiber_manual_record : Icons.radio_button_unchecked,
                size: 16,
                color: _sniffMode ? Colors.red : Colors.grey,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _sniffMode
                      ? 'SNIFF ${_sniffRadioMode.label}/${_sniffRole.label} ramek=$_sniffFrameCount'
                      : 'Sniff (Adeunis ARF8020AA)',
                  style: TextStyle(
                    fontSize: 12,
                    color: _sniffMode ? Colors.red.shade700 : Colors.grey.shade700,
                    fontWeight: _sniffMode ? FontWeight.bold : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!_sniffMode) ...[
                const Text('Radio:', style: TextStyle(fontSize: 11)),
                const SizedBox(width: 2),
                DropdownButton<AdeunisLinkMode>(
                  value: _sniffRadioMode,
                  isDense: true,
                  style: const TextStyle(fontSize: 11, color: Colors.black87),
                  items: AdeunisLinkMode.values.map((m) =>
                    DropdownMenuItem(value: m, child: Text(m.label)),
                  ).toList(),
                  onChanged: (v) => setState(() => _sniffRadioMode = v!),
                ),
                const SizedBox(width: 4),
                const Text('Role:', style: TextStyle(fontSize: 11)),
                const SizedBox(width: 2),
                DropdownButton<AdeunisRole>(
                  value: _sniffRole,
                  isDense: true,
                  style: const TextStyle(fontSize: 11, color: Colors.black87),
                  items: const [
                    DropdownMenuItem(value: AdeunisRole.other, child: Text('Other')),
                    DropdownMenuItem(value: AdeunisRole.meter, child: Text('Meter')),
                  ],
                  onChanged: (v) => setState(() => _sniffRole = v!),
                ),
              ],
            ],
          ),
          // Row 3c: Sniff actions (RAW switch + buttons)
          const SizedBox(height: 4),
          Row(
            children: [
              if (!_sniffMode) ...[
                const Text('RAW:', style: TextStyle(fontSize: 11)),
                Transform.scale(
                  scale: 0.75,
                  child: Switch(
                    value: _sniffRawBytes,
                    onChanged: (v) => setState(() => _sniffRawBytes = v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  icon: const Icon(Icons.medical_services_outlined, size: 14),
                  label: const Text('Probe', style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple.shade400,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  onPressed: _connected ? _probeAmber : null,
                ),
                const SizedBox(width: 6),
              ],
              if (_sniffMode) ...[
                ElevatedButton.icon(
                  icon: const Icon(Icons.bookmark_add, size: 14),
                  label: const Text('Mark&Save', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                  onPressed: _markAndSaveCapture,
                ),
                const Spacer(),
              ],
              ElevatedButton.icon(
                icon: Icon(_sniffMode ? Icons.stop : Icons.fiber_manual_record, size: 14),
                label: Text(_sniffMode ? 'Stop sniff' : 'Start sniff',
                    style: const TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _sniffMode ? Colors.grey.shade700 : Colors.red.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
                onPressed: _connected ? _toggleSniffMode : null,
              ),
            ],
          ),
          // Row 4: service operation status
          if (_readingParams) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _serviceStatus,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ),
                  TextButton(
                    onPressed: _cancelServiceOp,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                    ),
                    child: const Text('Anuluj', style: TextStyle(fontSize: 12, color: Colors.red)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _toggleBtListening() async {
    if (_btListening) {
      await _bt.stopListeningMode();
      setState(() => _btListening = false);
      _addLog('BT: nasluch zatrzymany');
    } else {
      final ok = await _bt.startListeningMode();
      setState(() => _btListening = ok);
      if (ok) {
        _addLog('BT: nasluch uruchomiony');
      } else {
        _addLog('BT: blad uruchomienia nasluchu: ${_bt.lastError}');
      }
    }
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
            // MVP: TX read command button for Apa162 zero-key meters
            if (m.kind == UnknownMeterKind.zeroKeyOk)
              IconButton(
                icon: const Icon(Icons.send, size: 18),
                tooltip: 'Wyślij komendę READ 0xA0 (Nr wodomierza)',
                color: fg,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => _sendApatorReadCommand(m, [0xA0]),
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

  /// MVP: Send Apator T2 READ command via Adeunis dongle.
  /// Strategy (mimicking what Apator BT module does in firmware):
  ///   1. Set dongle T2/Other mode
  ///   2. Pre-build the frame (with current ACC)
  ///   3. WAIT for next broadcast from target meter (which opens its 5s RX window)
  ///   4. IMMEDIATELY after broadcast detected → TX our frame
  ///   5. Wait up to 8s for RSP-UD response
  bool _readCmdInProgress = false;
  int? _quietExceptRadio; // when set, suppress logs for radios != this value
  Future<void> _sendApatorReadCommand(UnknownMeter m, List<int> regIds) async {
    if (_readCmdInProgress) return;
    final svc = SerialService.instance;
    if (svc.state != SerialState.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Najpierw połącz dongle')),
      );
      return;
    }
    setState(() => _readCmdInProgress = true);
    _quietExceptRadio = m.radioNum; // suppress logs from other meters
    final regHex = regIds.map((r) => '0x${r.toRadixString(16).toUpperCase().padLeft(2, '0')}').join(',');
    _addLog('═══ TX READ ID=${m.radioNum} regs=[$regHex] (quiet mode ON) ═══');

    StreamSubscription<Uint8List>? frameSub;
    StreamSubscription<Uint8List>? rawSub;
    try {
      // 1. Set dongle T2/Other
      _addLog('[1/5] setting Adeunis T2/Other...');
      await svc.enterCommandMode();
      await Future.delayed(const Duration(milliseconds: 150));
      await svc.setRadioMode(AdeunisLinkMode.t2);
      await Future.delayed(const Duration(milliseconds: 150));
      await svc.setRole(AdeunisRole.other);
      await Future.delayed(const Duration(milliseconds: 150));
      await svc.exitCommandMode();
      await Future.delayed(const Duration(milliseconds: 200));

      // 1b. PRELOAD frame BEFORE waiting for broadcast.
      //     Dongle should auto-TX in RX-window when next broadcast arrives.
      //     ACC value we don't know yet — use 0x01 (RSP-UD style) as initial preload.
      _addLog('[1b] preloading initial frame (ACC=0x01) before broadcast...');
      final preFrame = buildApatorReadFrame(
        radioNumber: m.radioNum,
        sw: 5, hw: 7, accessNumber: 0x01,
        regIds: regIds,
        now: DateTime.now(),
        aesKey: List<int>.filled(16, 0),
        withBlockCrcs: true,
      );
      await svc.txT2Frame(preFrame);
      _addLog('[1b] preload sent (${preFrame.length}B), dongle should auto-TX in next RX-window');

      // 2. Subscribe to RAW bytes for diagnostics during the whole flow
      DateTime? lastBcastTime;
      rawSub = svc.rawBytes.listen((data) {
        // After TX sent, log first 200ms of incoming bytes (likely echo or response)
        if (lastBcastTime != null &&
            DateTime.now().difference(lastBcastTime!).inMilliseconds < 1000) {
          final hex = data.take(30).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
          _addLog('  🔍 RAW[${data.length}] post-TX: $hex${data.length > 30 ? "..." : ""}');
        }
      });

      // 3. Build frame (will be sent right after we see a broadcast)
      _addLog('[2/5] building frame (will be sent after next broadcast)...');

      // 4. Wait for broadcast → immediately TX
      _addLog('[3/5] waiting for broadcast from ${m.radioNum} (max 35s)...');
      final broadcastCompleter = Completer<ParsedFrame?>();
      final responseCompleter = Completer<ParsedFrame?>();
      bool txSent = false;
      int txAcc = 0x01;

      final startTime = DateTime.now();
      frameSub = svc.frames.listen((raw) async {
        final p = parseRawFrame(raw);
        if (p == null) return;
        if (p.radioNum != m.radioNum) return;
        final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
        // Log ALL frames from target (even non-broadcast/non-RSP-UD)
        final ci = p.blockData.isNotEmpty ? p.blockData[0] : 0;
        final cHex = p.cField.toRadixString(16).padLeft(2, '0').toUpperCase();
        final ciHex = ci.toRadixString(16).padLeft(2, '0').toUpperCase();
        final rawHex = raw.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
        // Broadcast detection
        if (p.isBroadcast) {
          final bAcc = p.blockData.length > 1 ? p.blockData[1] : 0;
          _addLog('  📡 broadcast @ +${elapsedMs}ms TPL_ACC=0x${bAcc.toRadixString(16).padLeft(2, "0").toUpperCase()} (C=0x$cHex CI=0x$ciHex L=${p.lField})');
          if (!broadcastCompleter.isCompleted) {
            txAcc = (bAcc + 1) & 0xFF;
            broadcastCompleter.complete(p);
          }
        } else if (p.isRspUd && p.blockData.isNotEmpty && p.blockData[0] == 0x7A) {
          _addLog('  ✨✨✨ RSP-UD @ +${elapsedMs}ms !!!');
          _addLog('     HEX: $rawHex');
          if (!responseCompleter.isCompleted) responseCompleter.complete(p);
        } else {
          // Any other frame from target - very interesting!
          _addLog('  ❓ unusual frame @ +${elapsedMs}ms C=0x$cHex CI=0x$ciHex L=${p.lField}');
          _addLog('     HEX: $rawHex');
        }
      });

      // Timeout for broadcast wait
      Timer(const Duration(seconds: 35), () {
        if (!broadcastCompleter.isCompleted) broadcastCompleter.complete(null);
      });

      final bcast = await broadcastCompleter.future;
      if (bcast == null) {
        _addLog('[3/5] ❌ TIMEOUT: brak broadcastu od ${m.radioNum} w 35s — dongle nie widzi nakładki w T2/Other');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Timeout: brak broadcastu nakładki')),
        );
        return;
      }
      final bcastAcc = bcast.blockData.length > 1 ? bcast.blockData[1] : 0;
      _addLog('[3/5] ✅ broadcast detected — TPL_ACC=0x${bcastAcc.toRadixString(16).padLeft(2, "0").toUpperCase()}, '
              'using ACC=0x${txAcc.toRadixString(16).padLeft(2, "0").toUpperCase()} for command');

      // 5. Burst TX: try different framings + ACC values.
      //    Each "shot" pairs a frame format with an ACC value.
      _addLog('[4/5] burst TX: trying different framings + ACC values');
      lastBcastTime = DateTime.now();
      final accVariants = [0x01, (bcastAcc + 1) & 0xFF, bcastAcc & 0xFF];
      int shotIdx = 0;
      for (final acc in accVariants) {
        final wmbusFrame = buildApatorReadFrame(
          radioNumber: m.radioNum,
          sw: 5,
          hw: 7,
          accessNumber: acc,
          regIds: regIds,
          now: DateTime.now(),
          aesKey: List<int>.filled(16, 0),
          withBlockCrcs: true,
        );
        // Try 3 framings for each ACC
        final framings = [
          ('FF FE', Uint8List.fromList([0xFF, 0xFE, ...wmbusFrame])),
          ('raw (no prefix)', wmbusFrame),
          ('FF only', Uint8List.fromList([0xFF, ...wmbusFrame])),
        ];
        for (final (label, packet) in framings) {
          shotIdx++;
          _addLog('  TX[$shotIdx] ACC=0x${acc.toRadixString(16).padLeft(2, "0").toUpperCase()} prefix="$label" (${packet.length}B)');
          final ok = await svc.txRawBytes(packet);
          if (!ok) {
            _addLog('  ❌ TX[$shotIdx] write failed');
          }
          if (responseCompleter.isCompleted) {
            _addLog('  ✅ RSP-UD already received during burst!');
            break;
          }
          await Future.delayed(const Duration(milliseconds: 200));
        }
        if (responseCompleter.isCompleted) break;
      }
      txSent = true;

      // 6. Wait for RSP-UD up to 90s (3 broadcast cycles, ~30s each)
      _addLog('[5/5] waiting up to 90s for RSP-UD or further broadcasts...');
      Timer(const Duration(seconds: 90), () {
        if (!responseCompleter.isCompleted) responseCompleter.complete(null);
      });
      final result = await responseCompleter.future;
      txSent = txSent; // silence unused-var lint

      if (result == null) {
        _addLog('═══ ❌ TIMEOUT: brak RSP-UD w 8s po TX ═══');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Timeout: brak odpowiedzi RSP-UD')),
        );
        return;
      }

      // Decode the RSP-UD
      final ptDec = _decryptApa162(result, null);
      if (ptDec != null && isApa162Payload(ptDec)) {
        final r = parseApa162Payload(ptDec);
        final tagsStr = r.rawTags.entries.map((e) =>
          '0x${e.key.toRadixString(16).padLeft(2, '0').toUpperCase()}'
          '=${e.value.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join('')}'
        ).join('  ');
        _addLog('═══ ✅ RSP-UD ODEBRANE: $tagsStr ═══');
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('RSP-UD: $tagsStr'),
          duration: const Duration(seconds: 10),
        ));
      } else {
        _addLog('═══ ⚠ RSP-UD odebrane ale dekrypcja niepoprawna ═══');
      }
    } catch (e, st) {
      _addLog('TX exception: $e');
      debugPrint('TX exception: $e\n$st');
    } finally {
      await frameSub?.cancel();
      await rawSub?.cancel();
      _quietExceptRadio = null;
      if (mounted) setState(() => _readCmdInProgress = false);
    }
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

            // Parameter read/write button (Apator meters only)
            if (m.isApator) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _readingParams ? null : () {
                  Navigator.pop(context);
                  _showServiceDialog(m);
                },
                icon: _readingParams
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.settings_input_antenna),
                label: Text(_readingParams ? 'Operacja trwa...' : 'Odczyt / Zapis parametrow'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Register presets ────────────────────────────────────────────────────
  static const _presetBasic = [0x00, 0x02, 0x31, 0x33, 0x2E, 0x30];
  static const _presetFull = [
    0x00, 0x01, 0x02, 0x03, 0x10, 0x14, 0x17, 0x2E, 0x30, 0x31, 0x33,
  ];
  static const _presetConfig = [
    0x04, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x16,
  ];

  bool _readingParams = false;
  String _serviceStatus = '';
  Completer<Uint8List?>? _serviceCompleter;

  void _cancelServiceOp() {
    if (_serviceCompleter != null && !_serviceCompleter!.isCompleted) {
      _serviceCompleter!.complete(null);
    }
  }

  /// Show dialog to configure register read/write operation.
  void _showServiceDialog(UnknownMeter m) {
    // Readable registers (non-zero size)
    final readableRegs = kAtWmbus16Registers
        .where((r) => r.size > 0 && r.uid <= 0x35)
        .toList();

    final selected = Set<int>.from(_presetFull);
    int timeoutSec = 90;
    final pinCtrl = TextEditingController(text: '00000000');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return DraggableScrollableSheet(
            initialChildSize: 0.85,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            expand: false,
            builder: (_, sc) => Column(
              children: [
                // Handle bar
                Center(child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 4),
                  decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)),
                )),
                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(child: Text(
                        'Serwis: ${m.radioNum}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      )),
                      Text('SW=${m.sw} HW=${m.hw}',
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // Settings row: timeout + PIN
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      // Timeout
                      const Text('Timeout:', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 80,
                        child: DropdownButtonFormField<int>(
                          value: timeoutSec,
                          isDense: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 30, child: Text('30s')),
                            DropdownMenuItem(value: 60, child: Text('60s')),
                            DropdownMenuItem(value: 90, child: Text('90s')),
                            DropdownMenuItem(value: 120, child: Text('120s')),
                            DropdownMenuItem(value: 180, child: Text('180s')),
                            DropdownMenuItem(value: 300, child: Text('300s')),
                            DropdownMenuItem(value: 600, child: Text('600s')),
                          ],
                          onChanged: (v) => setSheetState(() => timeoutSec = v!),
                        ),
                      ),
                      const SizedBox(width: 16),
                      // PIN
                      const Text('PIN:', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: pinCtrl,
                          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            border: OutlineInputBorder(),
                            hintText: '00000000',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Preset buttons
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      ActionChip(
                        label: const Text('Podstawowe', style: TextStyle(fontSize: 12)),
                        onPressed: () => setSheetState(() {
                          selected.clear();
                          selected.addAll(_presetBasic);
                        }),
                      ),
                      ActionChip(
                        label: const Text('Pelny odczyt', style: TextStyle(fontSize: 12)),
                        onPressed: () => setSheetState(() {
                          selected.clear();
                          selected.addAll(_presetFull);
                        }),
                      ),
                      ActionChip(
                        label: const Text('Konfiguracja', style: TextStyle(fontSize: 12)),
                        onPressed: () => setSheetState(() {
                          selected.clear();
                          selected.addAll(_presetConfig);
                        }),
                      ),
                      ActionChip(
                        label: const Text('Wszystkie', style: TextStyle(fontSize: 12)),
                        onPressed: () => setSheetState(() {
                          selected.clear();
                          selected.addAll(readableRegs.map((r) => r.uid));
                        }),
                      ),
                      ActionChip(
                        label: const Text('Wyczysc', style: TextStyle(fontSize: 12)),
                        onPressed: () => setSheetState(() => selected.clear()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                // Register list
                Expanded(
                  child: ListView.builder(
                    controller: sc,
                    itemCount: readableRegs.length,
                    itemBuilder: (_, i) {
                      final reg = readableRegs[i];
                      final checked = selected.contains(reg.uid);
                      return CheckboxListTile(
                        dense: true,
                        value: checked,
                        onChanged: (v) => setSheetState(() {
                          if (v == true) {
                            selected.add(reg.uid);
                          } else {
                            selected.remove(reg.uid);
                          }
                        }),
                        title: Text(
                          '0x${reg.uid.toRadixString(16).toUpperCase().padLeft(2, '0')}  ${reg.name}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${reg.size}B  ${reg.writable ? "R/W" : "R"}',
                          style: TextStyle(fontSize: 11, color: reg.writable ? Colors.green : Colors.grey),
                        ),
                      );
                    },
                  ),
                ),
                // Action buttons
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: selected.isEmpty ? null : () {
                            Navigator.pop(ctx);
                            final pin = int.tryParse(pinCtrl.text.replaceAll(' ', ''), radix: 16) ?? 0;
                            final regs = selected.toList()..sort();
                            _executeServiceOp(m, regs, pin, timeoutSec, isWrite: false);
                          },
                          icon: const Icon(Icons.download, size: 18),
                          label: Text('Odczyt (${selected.length})', style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: null, // TODO: zapis w przyszlosci
                          icon: const Icon(Icons.upload, size: 18),
                          label: const Text('Zapis', style: TextStyle(fontSize: 13)),
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Execute a register read (or write) operation via USB dongle.
  Future<void> _executeServiceOp(
    UnknownMeter m,
    List<int> registerIds,
    int pin,
    int timeoutSec, {
    required bool isWrite,
  }) async {
    final svc = SerialService.instance;
    if (svc.state != SerialState.connected) {
      _addLog('USB: nie polaczono');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Najpierw polacz dongle USB')),
        );
      }
      return;
    }

    if (_readingParams) {
      _addLog('USB: operacja juz trwa');
      return;
    }

    setState(() {
      _readingParams = true;
      _serviceStatus = 'Przygotowanie...';
    });

    StreamSubscription<Uint8List>? frameSub;
    StreamSubscription<Uint8List>? rawSub;
    Timer? timeout;
    Timer? countdownTimer;
    int framesSeen = 0;

    try {
      final regData = Uint8List.fromList(registerIds.map((r) => r & 0xFF).toList());
      final device = ApatorDevice(
        radioNumber: m.radioNum,
        software1: m.sw,
        software2: m.sw,
        hardwareVersion: m.hw,
      );
      final serviceFrame = buildRegisterFrame(
        device: device,
        overlay: isWrite ? OverlayCode.write : OverlayCode.read,
        pin: pin,
        data: regData,
      );

      // Build wMBus T2 frame (no SOF — Adeunis txT2Frame adds FF FE prefix)
      final frame = BytesBuilder();
      frame.addByte(10 + serviceFrame.length); // L
      frame.addByte(0x53); // C-field: SND-UD
      frame.add([0x01, 0x06]); // M-field (Apator LE)
      frame.addByte(m.radioNum & 0xFF);
      frame.addByte((m.radioNum >> 8) & 0xFF);
      frame.addByte((m.radioNum >> 16) & 0xFF);
      frame.addByte((m.radioNum >> 24) & 0xFF);
      frame.addByte(m.sw);
      frame.addByte(m.hw);
      frame.addByte(0x51); // CI-field: CMD to device
      frame.add(serviceFrame);
      final wmbusFrame = frame.toBytes();

      final hexFrame = wmbusFrame.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
      final op = isWrite ? 'zapis' : 'odczyt';
      _addLog('USB: $op ${registerIds.length} rej. ID=${m.radioNum} timeout=${timeoutSec}s');
      _addLog('USB TX: $hexFrame');

      // Log raw bytes for debugging
      rawSub = svc.rawBytes.listen((data) {
        final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
        _addLog('RAW [${data.length}]: $hex');
      });

      // 1. Adeunis: enter command mode, set T2 + Other (bidirectional master), exit
      // NOTE: ARF8020AA fw 3.02 doesn't support T2 bidirectional. This TX path
      // can't actually deliver an OTA frame to the meter — kept for parity but
      // expected to fail. Use BT module path for register R/W instead.
      setState(() => _serviceStatus = 'Adeunis: command mode + T/Other...');
      final inCmd = await svc.enterCommandMode();
      if (!inCmd) {
        _addLog('USB: brak ACK z command mode (timeout)');
        return;
      }
      await svc.setRadioMode(AdeunisLinkMode.t1);
      await Future.delayed(const Duration(milliseconds: 100));
      await svc.setRole(AdeunisRole.other);
      await Future.delayed(const Duration(milliseconds: 100));
      await svc.exitCommandMode();
      await Future.delayed(const Duration(milliseconds: 200));

      // 2. TX wMBus frame in T2 RX-window: prefix FF FE [frame...]
      setState(() => _serviceStatus = 'TX ramki w T2...');
      final txOk = await svc.txT2Frame(wmbusFrame);
      if (!txOk) {
        _addLog('USB: blad txT2Frame');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 300));

      // 3. Wait for response
      final completer = Completer<Uint8List?>();
      _serviceCompleter = completer;

      // Countdown timer for UI
      final startTime = DateTime.now();
      countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !_readingParams) return;
        final elapsed = DateTime.now().difference(startTime).inSeconds;
        final remaining = timeoutSec - elapsed;
        if (remaining >= 0) {
          setState(() => _serviceStatus =
              'Czekam na nakladke... ${remaining}s  (ramek: $framesSeen)');
        }
      });

      setState(() => _serviceStatus = 'Czekam na nakladke... ${timeoutSec}s');
      _addLog('USB: preload OK, czekam na nakladke (~${timeoutSec}s)...');

      // Listen for ALL frames (not just this meter's) to see what's happening
      frameSub = svc.frames.listen((raw) {
        final parsed = parseRawFrame(raw);
        if (parsed == null) return;

        if (parsed.radioNum == m.radioNum) {
          framesSeen++;
          final bd = parsed.blockData;
          final bdHex = bd.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
          _addLog('USB RX #$framesSeen od ID=${m.radioNum}: CI=0x${bd.isNotEmpty ? bd[0].toRadixString(16) : "?"} ${bd.length}B');
          _addLog('  DATA: $bdHex');

          if (framesSeen == 1) {
            _addLog('USB: nakladka nadala — dongle powinien wyslac komende');
            setState(() => _serviceStatus = 'Komenda wyslana, czekam na odpowiedz...');
          } else {
            if (!completer.isCompleted) {
              completer.complete(raw);
            }
          }
        } else {
          _addLog('USB RX od ID=${parsed.radioNum} (nie nasz)');
        }
      });

      timeout = Timer(Duration(seconds: timeoutSec), () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      final responseFrame = await completer.future;

      if (responseFrame == null) {
        _addLog('USB: brak odpowiedzi (timeout ${timeoutSec}s, ramek: $framesSeen)');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(
              framesSeen == 0
                ? 'Nakladka nie nadala w ciagu ${timeoutSec}s'
                : 'Brak odpowiedzi na komende (ramek: $framesSeen)',
            )),
          );
        }
        return;
      }

      final parsed = parseRawFrame(responseFrame);
      if (parsed == null) {
        _addLog('USB: nie mozna sparsowac odpowiedzi');
        return;
      }

      final bd = parsed.blockData;
      final bdHex = bd.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
      _addLog('USB: odpowiedz ${bd.length}B');
      _addLog('USB RESP: $bdHex');

      for (int skip = 0; skip <= math.min(bd.length - 1, 10); skip++) {
        final regs = parseRegisterData(Uint8List.fromList(bd.sublist(skip)), registerIds);
        if (regs.isNotEmpty && regs.length > 2) {
          _addLog('USB: odczytano ${regs.length} rejestrow (offset=$skip)');
          if (mounted) _showRegisterResultsSimple(m, regs);
          return;
        }
      }

      _addLog('USB: odpowiedz otrzymana, surowe dane w logu');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Odpowiedz otrzymana — sprawdz logi')),
        );
      }
    } catch (e) {
      _addLog('USB: blad operacji: $e');
    } finally {
      frameSub?.cancel();
      rawSub?.cancel();
      timeout?.cancel();
      countdownTimer?.cancel();
      _serviceCompleter = null;
      if (mounted) {
        setState(() {
          _readingParams = false;
          _serviceStatus = '';
        });
      }
    }
  }

  void _showRegisterResultsSimple(UnknownMeter m, Map<int, Uint8List> regs) {
    _showRegisterResults(m, regs, null);
  }

  void _showRegisterResults(UnknownMeter m, Map<int, Uint8List> regs, ApatorResponse? response) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
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
            Text('Parametry: ${m.radioNum}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            if (response != null)
              Text('RSSI: ${response.rssi}  AFC: ${response.afc}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const Divider(height: 20),
            ...regs.entries.map((e) {
              final regInfo = registerById(e.key);
              final name = regInfo?.name ?? 'Reg 0x${e.key.toRadixString(16).toUpperCase()}';
              final value = formatRegisterValue(e.key, e.value);
              final hex = e.value.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(value, style: const TextStyle(fontSize: 14)),
                    Text(hex, style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.grey)),
                  ],
                ),
              );
            }),
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
