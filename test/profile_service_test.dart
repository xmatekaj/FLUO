import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluo/services/profile_service.dart';

void main() {
  test('parse js1.6 at16.inp', () {
    final file = File('/home/mateusz/Development/wmbus/development/apator profiles/js1.6 at16.inp');
    final bytes = file.readAsBytesSync();
    final profile = ProfileService.parseBytes(Uint8List.fromList(bytes));

    expect(profile.name, 'js1.6 at16');
    expect(profile.deviceType, 'AT-WMBUS-16-1');
    expect(profile.hardwareVersion, 7);
    expect(profile.profileVersion, 1);
    expect(profile.timeout, 90); // 0x5A = 90
    expect(profile.capacity, 1.0);
    expect(profile.manufacturingNumber, 1);
    expect(profile.parameters.isNotEmpty, true);

    print('Profile: ${profile.name}');
    print('Device: ${profile.deviceType}');
    print('HW: ${profile.hardwareVersion}, Version: ${profile.profileVersion}');
    print('Timeout: ${profile.timeout}s, Capacity: ${profile.capacity}');
    print('Mfg number: ${profile.manufacturingNumber}');
    print('Date: ${profile.date}');
    print('Parameters (${profile.parameters.length}):');
    for (final p in profile.parameters) {
      print('  $p');
    }
  });

  test('parse all .inp files', () {
    final dir = Directory('/home/mateusz/Development/wmbus/development/apator profiles');
    for (final entry in dir.listSync()) {
      if (entry is File && entry.path.endsWith('.inp')) {
        final bytes = entry.readAsBytesSync();
        final profile = ProfileService.parseBytes(Uint8List.fromList(bytes));
        print('\n--- ${entry.path.split('/').last} ---');
        print('  Name: ${profile.name}');
        print('  Device: ${profile.deviceType}');
        print('  HW: ${profile.hardwareVersion}, Params: ${profile.parameters.length}');
      }
    }
  });

  test('roundtrip serialization', () {
    final file = File('/home/mateusz/Development/wmbus/development/apator profiles/js1.6 at16.inp');
    final original = file.readAsBytesSync();
    final profile = ProfileService.parseBytes(Uint8List.fromList(original));

    // Serialize back
    final serialized = ProfileService.serializeProfile(profile);

    // Parse again
    final profile2 = ProfileService.parseBytes(serialized);

    expect(profile2.name, profile.name);
    expect(profile2.deviceType, profile.deviceType);
    expect(profile2.hardwareVersion, profile.hardwareVersion);
    expect(profile2.profileVersion, profile.profileVersion);
    expect(profile2.timeout, profile.timeout);
    expect(profile2.capacity, profile.capacity);
    expect(profile2.parameters.length, profile.parameters.length);

    for (int i = 0; i < profile.parameters.length; i++) {
      expect(profile2.parameters[i].register, profile.parameters[i].register);
      expect(profile2.parameters[i].bytes, profile.parameters[i].bytes);
    }
  });
}
