// Copyright (C) 2026 matekaj@proton.me
// GPL-3.0-or-later – see LICENSE
//
// W-MBus Water Meter Reader – Android app
// Reads Apator APA water meters via USB OTG W-MBus dongle (AES-128-CBC, OMS)

import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() => runApp(const WMBusApp());

class WMBusApp extends StatelessWidget {
  const WMBusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FLUO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}
