// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE

import 'package:flutter/material.dart';
import '../models/meter.dart';

Color _statusColor(MeterStatus s) {
  switch (s) {
    case MeterStatus.pending: return const Color(0xFFF5F5F5);
    case MeterStatus.ok:      return const Color(0xFFC8F5C8);
    case MeterStatus.alarm:   return const Color(0xFFFFF0A0);
    case MeterStatus.noKey:   return const Color(0xFFFFE0A0);
    case MeterStatus.failed:  return const Color(0xFFFFD0D0);
  }
}

Color _statusTextColor(MeterStatus s) {
  switch (s) {
    case MeterStatus.pending: return const Color(0xFF555555);
    case MeterStatus.ok:      return const Color(0xFF006600);
    case MeterStatus.alarm:   return const Color(0xFF7A5500);
    case MeterStatus.noKey:   return const Color(0xFF7A4500);
    case MeterStatus.failed:  return const Color(0xFF880000);
  }
}

String _fmtDt(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')} '
    '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';

String _fmtTime(DateTime dt) =>
    '${dt.hour.toString().padLeft(2,'0')}:'
    '${dt.minute.toString().padLeft(2,'0')}:'
    '${dt.second.toString().padLeft(2,'0')}';

void _showMeterDetail(BuildContext context, Meter meter) {
  final fg = _statusTextColor(meter.status);
  final alarmList = meter.alarms.where((a) => a != 'OK').toList();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Text(
            '${meter.building}  ${meter.staircase}${meter.apartment}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            meter.status.label,
            style: TextStyle(fontSize: 13, color: fg, fontWeight: FontWeight.w600),
          ),
          const Divider(height: 20),

          // Identifiers
          _InfoRow('Radio ID', meter.displayId),
          if (meter.serial.isNotEmpty) _InfoRow('Serial', meter.serial),

          // Current reading
          if (meter.volumeM3 != null) ...[
            const SizedBox(height: 8),
            _SectionHeader('Current reading'),
            _InfoRow('Volume', '${meter.volumeM3!.toStringAsFixed(3)} m³'),
            if (meter.readAt != null)
              _InfoRow('Read at', _fmtDt(meter.readAt!)),
          ],

          // Alarms
          if (alarmList.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionHeader('Alarms'),
            ...alarmList.map((a) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                const SizedBox(width: 6),
                Text(a, style: const TextStyle(fontSize: 13)),
              ]),
            )),
          ],

          // History
          if (meter.history.isNotEmpty) ...[
            const SizedBox(height: 8),
            _SectionHeader('History'),
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Row(children: [
                SizedBox(width: 160, child: Text('Date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey))),
                Text('Volume (m³)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey)),
              ]),
            ),
            ...meter.history.map((h) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    h.date != null ? _fmtDt(h.date!) : '—',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Text(
                  h.volumeM3.toStringAsFixed(3),
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                ),
              ]),
            )),
          ],

          if (meter.volumeM3 == null && alarmList.isEmpty && meter.history.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('No data received yet.', style: TextStyle(color: Colors.grey)),
            ),
        ],
      ),
    ),
  );
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.blueGrey.shade700,
        letterSpacing: 0.5,
      ),
    ),
  );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: const TextStyle(fontSize: 13, color: Colors.grey)),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 13)),
        ),
      ],
    ),
  );
}

class MeterTile extends StatelessWidget {
  final int index;
  final Meter meter;
  final VoidCallback onConfirm;
  final VoidCallback onReset;

  const MeterTile({
    super.key,
    required this.index,
    required this.meter,
    required this.onConfirm,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final bg   = _statusColor(meter.status);
    final fg   = _statusTextColor(meter.status);
    final alarms = meter.alarms.where((a) => a != 'OK').join(', ');

    return Container(
      color: bg,
      child: ListTile(
        dense: true,
        onTap: () => _showMeterDetail(context, meter),
        leading: CircleAvatar(
          radius: 14,
          backgroundColor: bg == const Color(0xFFF5F5F5)
              ? Colors.grey.shade300
              : bg.withValues(alpha: 0.6),
          child: Text(
            '$index',
            style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.bold),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${meter.building}  ${meter.staircase}${meter.apartment}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: fg,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              meter.status.label,
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('ID: ${meter.displayId}  ', style: TextStyle(fontSize: 11, color: fg)),
                if (meter.serial.isNotEmpty)
                  Text('S/N: ${meter.serial}', style: TextStyle(fontSize: 11, color: fg)),
              ],
            ),
            if (meter.volumeM3 != null)
              Text(
                'Vol: ${meter.volumeM3!.toStringAsFixed(3)} m³'
                '${meter.readAt != null ? "  @ ${_fmtTime(meter.readAt!)}" : ""}',
                style: TextStyle(fontSize: 11, color: fg),
              ),
            if (alarms.isNotEmpty)
              Text('⚠ $alarms', style: TextStyle(fontSize: 11, color: fg)),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, size: 18, color: fg),
          onSelected: (v) => v == 'confirm' ? onConfirm() : onReset(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'confirm', child: Text('✅ Mark confirmed')),
            PopupMenuItem(value: 'reset',   child: Text('⏳ Reset to pending')),
          ],
        ),
      ),
    );
  }
}
