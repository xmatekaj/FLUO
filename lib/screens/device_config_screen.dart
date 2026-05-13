// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE
//
// Screen for connecting to Apator module via Bluetooth and reading/writing
// register configuration. Supports loading Inkasoid profiles (.inp).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../models/apator_profile.dart';
import '../services/apator_bt_service.dart';
import '../services/apator_bt_impl.dart';
import '../services/profile_service.dart';

class DeviceConfigScreen extends StatefulWidget {
  const DeviceConfigScreen({super.key});

  @override
  State<DeviceConfigScreen> createState() => _DeviceConfigScreenState();
}

class _DeviceConfigScreenState extends State<DeviceConfigScreen> {
  final _bt = ApatorBtServiceImpl.instance;
  ApatorBtState _btState = ApatorBtState.disconnected;
  StreamSubscription<ApatorBtState>? _btSub;

  // Device list
  List<({String name, String address})> _devices = [];
  bool _scanning = false;

  // Connected device info
  final _pinController = TextEditingController(text: '00000000');
  final _radioController = TextEditingController();
  int _hwVersion = 7;
  int _sw1 = 5;
  int _sw2 = 5;

  // Response / register data
  String _status = '';
  ApatorResponse? _lastResponse;
  ApatorProfile? _loadedProfile;

  @override
  void initState() {
    super.initState();
    _btSub = _bt.connectionState.listen((s) => setState(() => _btState = s));
  }

  @override
  void dispose() {
    _btSub?.cancel();
    _pinController.dispose();
    _radioController.dispose();
    super.dispose();
  }

  int get _pin {
    final text = _pinController.text.replaceAll(' ', '');
    return int.tryParse(text, radix: 16) ?? 0;
  }

  int get _radioNumber => int.tryParse(_radioController.text) ?? 0;

  ApatorDevice get _device => ApatorDevice(
        radioNumber: _radioNumber,
        software1: _sw1,
        software2: _sw2,
        hardwareVersion: _hwVersion,
      );

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _devices = [];
    });
    _setStatus('Szukam sparowanych i nowych urzadzen BT...');

    // Register callback for newly discovered devices during scan.
    _bt.onDevicesUpdated = (devices) {
      if (mounted) setState(() => _devices = devices);
    };

    try {
      final devices = await _bt.discover();
      if (mounted) {
        setState(() => _devices = devices);
        final err = _bt.lastError;
        if (err != null) {
          _setStatus('$err\n\nZnaleziono ${devices.length} urzadzen');
        } else if (devices.isEmpty) {
          _setStatus('Nie znaleziono sparowanych urzadzen.\n'
              'Skanowanie nowych trwa 15s...\n\n'
              'Jesli modul Apator nie pojawia sie:\n'
              '1. Sprawdz czy modul jest wlaczony\n'
              '2. Sparuj go recznie w Ustawieniach Android > Bluetooth\n'
              '   (MAC: patrz naklejka na module)\n'
              '3. Wrocz tutaj i kliknij "Szukaj" ponownie');
        } else {
          _setStatus('Znaleziono ${devices.length} urzadzen. Skanowanie nowych trwa 15s...');
        }
      }
    } catch (e) {
      _setStatus('Blad skanowania: $e\n\n${_bt.lastError ?? ""}');
    }

    // Scanning stops automatically after 15s in the service.
    Future.delayed(const Duration(seconds: 16), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  Future<void> _connect(String address) async {
    _setStatus('Laczenie...');
    final ok = await _bt.connect(address);
    _setStatus(ok ? 'Polaczono' : 'Nie udalo sie polaczyc');
  }

  Future<void> _disconnect() async {
    await _bt.disconnect();
    _setStatus('Rozlaczono');
  }

  Future<void> _readRegisters() async {
    // Read common registers for AT-WMBUS-16-1
    const regsToRead = [
      0x00, 0x01, 0x02, 0x03, 0x10, 0x11, // date, flow, capacity, wmbus
      0x17, // failures
      0x2E, 0x2F, 0x30, // voltage, detectors, temp
      0x31, 0x33, // meter number, battery days
    ];

    _setStatus('Odczyt rejestrow...');
    final response = await _bt.readRegisters(
      device: _device,
      pin: _pin,
      registerIds: regsToRead,
    );

    if (response == null) {
      _setStatus('Brak odpowiedzi (timeout)');
      return;
    }

    setState(() => _lastResponse = response);

    if (response.isOk) {
      _setStatus('Odczyt OK (${response.data.length} B, RSSI: ${response.rssi})');
    } else {
      _setStatus('Blad: ${response.overlayError.name} / ${response.btError.name}');
    }
  }

  Future<void> _writeProfile() async {
    if (_loadedProfile == null) {
      _setStatus('Najpierw wczytaj profil .inp');
      return;
    }

    // Build write data array similar to AT_WMBUS_16_1.getArrayToWrite()
    final params = _loadedProfile!.writableParameters;
    if (params.isEmpty) {
      _setStatus('Brak parametrow do zapisu');
      return;
    }

    // Skip manufacturing number (0xA0) and current capacity (0xA1) – like Inkasoid
    final filteredParams = params
        .where((p) => p.register != 0xA0 && p.register != 0xA1)
        .toList();

    // Build register data: [ster][0xFF][0xFF][0x00] + [reg_id][len][data...]...
    final buf = BytesBuilder();
    // Control byte (ster) – start with 0x00, set bits based on params
    int ster = 0;
    final hasCapInit = params.any((p) => p.register == 0xA1);
    final hasRtc = params.any((p) => p.register == 0xA3);
    if (hasCapInit) ster |= 0x08;
    if (hasRtc) ster |= 0x10;

    // Find control byte param (reg 0x02) if present
    final ctrlParam = filteredParams.where((p) => p.register == 0x02).firstOrNull;
    if (ctrlParam != null && ctrlParam.bytes.isNotEmpty) {
      ster |= ctrlParam.bytes[0];
    }

    buf.addByte(ster);
    buf.addByte(0xFF);
    buf.addByte(0xFF);
    buf.addByte(0x00);

    for (final p in filteredParams) {
      if (p.register == 0x02) continue; // control byte already handled
      buf.addByte(p.register & 0xFF);
      buf.addByte(p.bytes.length);
      buf.add(p.bytes);
    }

    _setStatus('Zapis profilu (${filteredParams.length} parametrow)...');
    final response = await _bt.writeRegisters(
      device: _device,
      pin: _pin,
      registerData: buf.toBytes(),
    );

    if (response == null) {
      _setStatus('Brak odpowiedzi (timeout)');
      return;
    }

    setState(() => _lastResponse = response);

    if (response.isOk) {
      _setStatus('Zapis OK');
    } else {
      _setStatus('Blad zapisu: ${response.overlayError.name}');
    }
  }

  Future<void> _pickBuiltinProfile() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Wybierz profil', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          ...kBuiltinProfiles.map((p) => ListTile(
                leading: const Icon(Icons.water_drop_outlined),
                title: Text(p.label),
                onTap: () => Navigator.pop(ctx, p.asset),
              )),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Wczytaj z pliku .inp...'),
            onTap: () => Navigator.pop(ctx, '_file_picker_'),
          ),
        ],
      ),
    );

    if (selected == null) return;

    try {
      ApatorProfile? profile;
      if (selected == '_file_picker_') {
        profile = await ProfileService.pickAndParse();
      } else {
        profile = await ProfileService.loadAsset(selected);
      }
      if (profile != null) {
        setState(() => _loadedProfile = profile);
        _setStatus('Profil: ${profile.name} (${profile.parameters.length} parametrow)');
      }
    } catch (e) {
      _setStatus('Blad odczytu profilu: $e');
    }
  }

  void _setStatus(String s) => setState(() => _status = s);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connected = _btState == ApatorBtState.connected;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Konfiguracja Apator'),
        actions: [
          // Connection indicator
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(
              connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: connected ? Colors.green : Colors.grey,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Bluetooth connection ──
          _sectionTitle('Polaczenie Bluetooth'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _scanning ? null : _scan,
                          icon: _scanning
                              ? const SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.search),
                          label: const Text('Szukaj urzadzen'),
                        ),
                      ),
                      if (connected) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _disconnect,
                          child: const Text('Rozlacz'),
                        ),
                      ],
                    ],
                  ),
                  if (_devices.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ..._devices.map((d) => Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          child: InkWell(
                            onTap: () => _connect(d.address),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  const Icon(Icons.bluetooth, size: 24),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(d.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                                        Text(d.address, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                      ],
                                    ),
                                  ),
                                  FilledButton(
                                    onPressed: () => _connect(d.address),
                                    child: const Text('Polacz'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Device parameters ──
          _sectionTitle('Parametry urzadzenia'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  TextField(
                    controller: _radioController,
                    decoration: const InputDecoration(
                      labelText: 'Numer radiowy',
                      hintText: 'np. 12345678',
                      isDense: true,
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _pinController,
                    decoration: const InputDecoration(
                      labelText: 'PIN (hex)',
                      hintText: '00000000',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _hwVersion,
                          decoration: const InputDecoration(
                            labelText: 'HW ver',
                            isDense: true,
                          ),
                          items: [3, 7, 8].map((v) => DropdownMenuItem(
                            value: v, child: Text('$v'),
                          )).toList(),
                          onChanged: (v) => setState(() => _hwVersion = v!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _sw1,
                          decoration: const InputDecoration(
                            labelText: 'SW1',
                            isDense: true,
                          ),
                          items: List.generate(10, (i) => DropdownMenuItem(
                            value: i, child: Text('$i'),
                          )),
                          onChanged: (v) => setState(() => _sw1 = v!),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _sw2,
                          decoration: const InputDecoration(
                            labelText: 'SW2',
                            isDense: true,
                          ),
                          items: List.generate(10, (i) => DropdownMenuItem(
                            value: i, child: Text('$i'),
                          )),
                          onChanged: (v) => setState(() => _sw2 = v!),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Actions ──
          _sectionTitle('Operacje'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: connected ? _readRegisters : null,
                          icon: const Icon(Icons.download),
                          label: const Text('Odczytaj rejestry'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickBuiltinProfile,
                          icon: const Icon(Icons.folder_open),
                          label: Text(_loadedProfile != null
                              ? 'Profil: ${_loadedProfile!.name}'
                              : 'Wczytaj profil .inp'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: connected && _loadedProfile != null ? _writeProfile : null,
                          icon: const Icon(Icons.upload),
                          label: const Text('Zapisz profil do urzadzenia'),
                          style: FilledButton.styleFrom(
                            backgroundColor: cs.error,
                            foregroundColor: cs.onError,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Status ──
          if (_status.isNotEmpty) ...[
            _sectionTitle('Status'),
            Card(
              color: cs.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_status, style: const TextStyle(fontFamily: 'monospace')),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Response data ──
          if (_lastResponse != null) ...[
            _sectionTitle('Ostatnia odpowiedz'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoRow('Radio', '${_lastResponse!.radioNumber}'),
                    _infoRow('RSSI', '${_lastResponse!.rssi}'),
                    _infoRow('AFC', '${_lastResponse!.afc}'),
                    _infoRow('BT error', _lastResponse!.btError.name),
                    _infoRow('Overlay error', _lastResponse!.overlayError.name),
                    if (_lastResponse!.data.isNotEmpty) ...[
                      const Divider(),
                      const Text('Dane (hex):', style: TextStyle(fontWeight: FontWeight.w500)),
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SelectableText(
                          _formatHex(_lastResponse!.data),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],

          // ── Loaded profile preview ──
          if (_loadedProfile != null) ...[
            const SizedBox(height: 16),
            _sectionTitle('Wczytany profil'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoRow('Nazwa', _loadedProfile!.name),
                    _infoRow('Urzadzenie', _loadedProfile!.deviceType),
                    _infoRow('HW', '${_loadedProfile!.hardwareVersion}'),
                    _infoRow('Parametry', '${_loadedProfile!.parameters.length}'),
                    _infoRow('Do zapisu', '${_loadedProfile!.writableParameters.length}'),
                    const Divider(),
                    ..._loadedProfile!.parameters.map((p) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            '${p.name}: ${p.hexValue}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: p.writable ? null : cs.outline,
                            ),
                          ),
                        )),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 120, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500))),
            Expanded(child: Text(value)),
          ],
        ),
      );

  String _formatHex(Uint8List data) {
    final sb = StringBuffer();
    for (int i = 0; i < data.length; i++) {
      if (i > 0 && i % 16 == 0) sb.writeln();
      sb.write(data[i].toRadixString(16).padLeft(2, '0').toUpperCase());
      sb.write(' ');
    }
    return sb.toString().trim();
  }
}
