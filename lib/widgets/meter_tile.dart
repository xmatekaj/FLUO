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
                '${meter.readAt != null ? "  @ ${_fmt(meter.readAt!)}" : ""}',
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

  String _fmt(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';
}
