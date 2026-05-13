// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE

import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/apator_profile.dart';
import '../services/profile_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  ApatorProfile? _profile;
  String? _fileName;
  bool _loading = false;

  Future<void> _pickProfile() async {
    setState(() => _loading = true);
    try {
      final profile = await ProfileService.pickAndParse();
      if (profile != null) {
        setState(() {
          _profile = profile;
          _fileName = profile.name;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Blad odczytu profilu: $e')),
        );
      }
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName ?? 'Profile Apator'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Wczytaj profil .inp',
            onPressed: _loading ? null : _pickProfile,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profile == null
              ? _buildEmpty(cs)
              : _buildProfile(cs),
    );
  }

  Future<void> _loadAsset(String asset) async {
    setState(() => _loading = true);
    try {
      final profile = await ProfileService.loadAsset(asset);
      setState(() {
        _profile = profile;
        _fileName = profile.name;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Blad: $e')),
        );
      }
    } finally {
      setState(() => _loading = false);
    }
  }

  Widget _buildEmpty(ColorScheme cs) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Wbudowane profile', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...kBuiltinProfiles.map((p) => Card(
              child: ListTile(
                leading: const Icon(Icons.water_drop_outlined),
                title: Text(p.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _loadAsset(p.asset),
              ),
            )),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _pickProfile,
          icon: const Icon(Icons.folder_open),
          label: const Text('Wczytaj z pliku...'),
        ),
      ],
    );
  }

  Widget _buildProfile(ColorScheme cs) {
    final p = _profile!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Header card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.water_drop, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _infoRow('Urzadzenie', p.deviceType),
                _infoRow('Wersja HW', '${p.hardwareVersion}'),
                _infoRow('Wersja profilu', '${p.profileVersion}'),
                _infoRow('Timeout', '${p.timeout}s'),
                if (p.capacity != null)
                  _infoRow('Pojemnosc', '${p.capacity} m\u00B3'),
                if (p.manufacturingNumber != null)
                  _infoRow('Numer fabryczny', '${p.manufacturingNumber}'),
                if (p.oldPin != null)
                  _infoRow('Stary PIN', '${p.oldPin}'),
                if (p.newPin != null)
                  _infoRow('Nowy PIN', '${p.newPin}'),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Parameters header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Parametry (${p.parameters.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 8),

        // Parameter list
        ...p.parameters.map((param) => _buildParamTile(param, cs)),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildParamTile(ProfileParameter param, ColorScheme cs) {
    final regHex = '0x${param.register.toRadixString(16).toUpperCase().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: param.writable ? cs.primaryContainer : cs.surfaceContainerHighest,
          child: Text(
            regHex,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: param.writable ? cs.onPrimaryContainer : cs.onSurfaceVariant,
            ),
          ),
        ),
        title: Text(param.name, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          param.hexValue,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: cs.onSurfaceVariant,
          ),
        ),
        trailing: param.writable
            ? Icon(Icons.edit_outlined, size: 18, color: cs.primary)
            : Icon(Icons.lock_outlined, size: 18, color: cs.outline),
        onTap: () => _showParamDetails(param),
      ),
    );
  }

  void _showParamDetails(ProfileParameter param) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(param.name, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            _infoRow('Rejestr', '0x${param.register.toRadixString(16).toUpperCase()} (${param.register})'),
            _infoRow('Rozmiar', '${param.bytes.length} B'),
            _infoRow('Zapis', param.writable ? 'Tak' : 'Tylko odczyt'),
            const SizedBox(height: 8),
            Text('Dane (hex):', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                param.hexValue,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
            ),
            if (param.bytes.length == 4) ...[
              const SizedBox(height: 8),
              _infoRow('Wartosc (LE uint32)',
                  '${ByteData.sublistView(Uint8List.fromList(param.bytes)).getUint32(0, Endian.little)}'),
            ],
            if (param.bytes.length == 2) ...[
              const SizedBox(height: 8),
              _infoRow('Wartosc (LE uint16)',
                  '${ByteData.sublistView(Uint8List.fromList(param.bytes)).getUint16(0, Endian.little)}'),
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
