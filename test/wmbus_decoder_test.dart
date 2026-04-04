// Unit tests for wmbus_decoder.dart
// Fixtures: real frames from W-MBus received frames_APATOR.xls,
//           W-MBus received frames.xls, wm.xls
//
// Note on CRC: block CRCs in XLS files do NOT pass the EN 13757 check.
// crcOk=false is therefore EXPECTED for all XLS-sourced frames.
// The fallback path (raw data without CRC stripping) is tested below.

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluo/services/wmbus_decoder.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List h(String hex) => Uint8List.fromList(
    List.generate(hex.length ~/ 2, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));

List<int> zeroKey() => List.filled(16, 0);

// ---------------------------------------------------------------------------
// Fixtures – Apator 162 (CI=0x7A, AES-128-CBC zero-key)
// ---------------------------------------------------------------------------

class _Apa162Fixture {
  final String desc;
  final String rawHex;
  final int radioNum;
  final double volumeM3;
  final String ivHex;
  final String plaintextPrefix;
  const _Apa162Fixture(
      {required this.desc,
      required this.rawHex,
      required this.radioNum,
      required this.volumeM3,
      required this.ivHex,
      required this.plaintextPrefix});
}

const _apa162 = [
  _Apa162Fixture(
    desc: 'Apator162 #1 radio=2684945',
    rawHex:
        'ff644401064549680205077ae9006085e68b7bf49e58fda7720aa0293a8b95b9'
        'bcf148adb53ab5c56aa710eb1111e7a67d82aa4c3e0606f273a308c4e10fd219'
        '7e67f338ed06adc87022d3c2ef8f8605dc74f485f8ec97449d80f218fff22f52'
        'abdb2a0d09bf983e5d8bd8b716114e0572',
    radioNum: 2684945,
    volumeM3: 133.447,
    ivHex: '0106454968020507e9e9e9e9e9e9e9e9',
    plaintextPrefix: '2f2f0f13',
  ),
  _Apa162Fixture(
    desc: 'Apator162 #2 radio=2675450',
    rawHex:
        'ff644401065054670205077ad90060856cc8ecdca5331933f51cd034b65fac6bd'
        '4fa95877f53969980ca8c12dead44de89ec7d03d7a0e1bf1e87fdf4370f4092e'
        'b15794202949aa3d9b93eb0bd9661850e3d6be8af8da4419b6c36ba2d74cbf10'
        '630498f21fb29a94edd7011e1ef88276f',
    radioNum: 2675450,
    volumeM3: 79.582,
    ivHex: '0106505467020507d9d9d9d9d9d9d9d9',
    plaintextPrefix: '2f2f0f1d',
  ),
  _Apa162Fixture(
    desc: 'Apator162 #3 radio=1151537',
    rawHex:
        'ff644401063715150105077a2e00608570dee539093940ca1976311752e331dc'
        '28928747992f29d3471357e1f755e7acfe5ec7480beeff53358c2c42b004aae5'
        '1e15bd3228d134a59e8f43f5231adc62ba8bbc7699555b8b5076a689facfbfb7'
        '53f1f44562e5d848195575f1bc375f9c79',
    radioNum: 1151537,
    volumeM3: 70.672,
    ivHex: '01063715150105072e2e2e2e2e2e2e2e',
    plaintextPrefix: '2f2f0f33',
  ),
  _Apa162Fixture(
    desc: 'Apator162 #4 radio=1597974',
    rawHex:
        'ff644401067479590105077aad00608599450b5d9cfae35670730020b7167c06'
        'b85d7034ba1110ee1ff83c5e70dca3bd0581da60ec0c7ffc3172b6d2f0dab2e1'
        'd9d45a7457c52fe0263c4fd49b62b1c1017e4c0b67669a9664b8effb9c66c502'
        '088b22f56305e740f62529d23aab707067',
    radioNum: 1597974,
    volumeM3: 27.87,
    ivHex: '0106747959010507adadadadadadadad',
    plaintextPrefix: '2f2f0f2d',
  ),
  _Apa162Fixture(
    desc: 'Apator162 #5 radio=1230737',
    rawHex:
        'ff644401063707230105077afd00608536e7ddb311fdc34b6bb3b0193aeb7f73'
        '1840abcf42b2c25ba8ed8156c94276f2d597ea09efff841c03a5996ffcb5b549'
        'da07a5cb98d05964af4ab46e6d4e61e57a1cb1626eaaee4df4b01c1d19f947ff'
        '6896dd429d511a44e4677f526334bf1283',
    radioNum: 1230737,
    volumeM3: 130.115,
    ivHex: '0106370723010507fdfdfdfdfdfdfdfd',
    plaintextPrefix: '2f2f0f23',
  ),
];

// ---------------------------------------------------------------------------
// Fixtures – Apator ELL (CI=0x8C+0x7A, real AES key)
// ---------------------------------------------------------------------------

class _ApaEllFixture {
  final String desc;
  final String rawHex;
  final int radioNum;
  final String aesKey;
  final double volumeM3;
  final String ivHex;
  final String plaintextPrefix;
  const _ApaEllFixture(
      {required this.desc,
      required this.rawHex,
      required this.radioNum,
      required this.aesKey,
      required this.volumeM3,
      required this.ivHex,
      required this.plaintextPrefix});
}

const _apaEll = [
  _ApaEllFixture(
    desc: 'ApaELL #1 radio=10780203',
    rawHex:
        'ff57440106030278101a078cc0b57a6c005085fd47c8f2ac18d2d2eb23f139f2'
        'f397fdfa6944f046c9faaf0a0ed6fde2ff7e7dbd7aae5d8d2c707726e3e19b71'
        'd5cbcdcfd8adcc9562cc8dd498210746f94666548a94ce95084c3237b9d2b2c8'
        '062f6950',
    radioNum: 10780203,
    aesKey: '9b1fe0bda71eaac7fa45a16b1e2f2991',
    volumeM3: 27.018,
    ivHex: '0106030278101a076c6c6c6c6c6c6c6c',
    plaintextPrefix: '2f2f0413',
  ),
  _ApaEllFixture(
    desc: 'ApaELL #2 radio=10876333',
    rawHex:
        'ff57440106336387101a078cc09f7a77305085dd2e478f7b6fd3c1db88fde581'
        'b94f54169187d5cc144e3e9ef2f63b872cb38c81c7dc2f013c07681883894c20'
        '460d4e03537393a957d86b146e51764db8e7e0d2d17567a4e5b3c78e4714bd22'
        '3df0805a',
    radioNum: 10876333,
    aesKey: 'aee11d33a7a8288e43c4cb5e770d1d7b',
    volumeM3: 1.147,
    ivHex: '0106336387101a077777777777777777',
    plaintextPrefix: '2f2f0413',
  ),
  _ApaEllFixture(
    desc: 'ApaELL #3 radio=10776049',
    rawHex:
        'ff57440106496077101a078cc0f77a4100508529bbeedf22a62e1a5c675ad31d'
        'd8a4e7584bd66c4b5ff59d5b55218aba2524051163f6e013380a702e52177df4'
        '11e490a7831c0112c761876c8a9b82bbc7efef220f8b87be5be1f53ee707bc1f'
        '79fbe24b',
    radioNum: 10776049,
    aesKey: '3d651d15d5266927a7d82f4be01a88c5',
    volumeM3: 16.189,
    ivHex: '0106496077101a074141414141414141',
    plaintextPrefix: '2f2f0413',
  ),
];

// ---------------------------------------------------------------------------
// Fixtures – Techem MK Radio 3 water (CI=0xA2, unencrypted)
// ---------------------------------------------------------------------------

class _TechWaterFixture {
  final String desc;
  final String rawHex;
  final int radioNum;
  final double totalM3;
  final double prevM3;
  final double currM3;
  const _TechWaterFixture(
      {required this.desc,
      required this.rawHex,
      required this.radioNum,
      required this.totalM3,
      required this.prevM3,
      required this.currM3});
}

const _techWater = [
  _TechWaterFixture(
    desc: 'Techem water #1 radio=51760996',
    rawHex:
        'ff25446850960976517472a2069f239f05c00ea800000008090913120c0d0a0d'
        '0e100c0b0d1311050b0b09080a080b0d0b5a',
    radioNum: 51760996,
    totalM3: 160.7,
    prevM3: 143.9,
    currM3: 16.8,
  ),
  _TechWaterFixture(
    desc: 'Techem water #2 radio=51760995',
    rawHex:
        'ff25446850950976517462a2069f232304c00e160110000b131315171a1a1419'
        '13121719161815171618191617130b151150',
    radioNum: 51760995,
    totalM3: 133.7,
    prevM3: 105.9,
    currM3: 27.8,
  ),
  _TechWaterFixture(
    desc: 'Techem water #3 radio=51762307',
    rawHex:
        'ff25446850072376517472a2069f239e01c00e5a0000000506060807080f080b'
        '0503040505070505070605090a0709090757',
    radioNum: 51762307,
    totalM3: 50.4,
    prevM3: 41.4,
    currM3: 9.0,
  ),
];

// ---------------------------------------------------------------------------
// Fixtures – Techem FHKV Data III HCA (CI=0xA0, unencrypted)
// ---------------------------------------------------------------------------

class _TechHcaFixture {
  final String desc;
  final String rawHex;
  final int radioNum;
  final int prevHca;
  final int currHca;
  const _TechHcaFixture(
      {required this.desc,
      required this.rawHex,
      required this.radioNum,
      required this.prevHca,
      required this.currHca});
}

const _techHca = [
  _TechHcaFixture(
    desc: 'Techem HCA #1 radio=10973102',
    rawHex:
        'ff28446850023197106980a011bf246f03c00e000096098e0900000000000018'
        '5247655053445a4349312d1d11000000000000004e',
    radioNum: 10973102,
    prevHca: 879,
    currHca: 0,
  ),
  _TechHcaFixture(
    desc: 'Techem HCA #2 radio=10977178',
    rawHex:
        'ff28446850787197106980a011bf244406c00e000088099209000000000f1f3c'
        '8f7f829c98a8b1a69b7a0200000000000000000055',
    radioNum: 10977178,
    prevHca: 1604,
    currHca: 0,
  ),
];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ── parseRawFrame – Apator 162 ─────────────────────────────────────────────
  group('parseRawFrame – Apator 162', () {
    for (final fx in _apa162) {
      test('${fx.desc} – radioNum', () {
        final parsed = parseRawFrame(h(fx.rawHex));
        expect(parsed, isNotNull);
        expect(parsed!.radioNum, equals(fx.radioNum));
      });

      test('${fx.desc} – manufacturer=APA (M=0106)', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        expect(parsed.mBytes[0], equals(0x01));
        expect(parsed.mBytes[1], equals(0x06));
      });

      test('${fx.desc} – isApaFrame', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        expect(isApaFrame(parsed.mBytes), isTrue);
      });

      test('${fx.desc} – crcOk=false (XLS block CRCs are broken)', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        expect(parsed.crcOk, isFalse);
      });

      test('${fx.desc} – blockData[0]=CI=0x7A', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        expect(parsed.blockData[0], equals(0x7A));
      });
    }
  });

  // ── parseRawFrame – Apator ELL ────────────────────────────────────────────
  group('parseRawFrame – Apator ELL', () {
    for (final fx in _apaEll) {
      test('${fx.desc} – radioNum', () {
        final parsed = parseRawFrame(h(fx.rawHex));
        expect(parsed, isNotNull);
        expect(parsed!.radioNum, equals(fx.radioNum));
      });

      test('${fx.desc} – blockData[0]=CI=0x8C', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        expect(parsed.blockData[0], equals(0x8C));
      });
    }
  });

  // ── parseRawFrame – Techem ────────────────────────────────────────────────
  group('parseRawFrame – Techem water', () {
    for (final fx in _techWater) {
      test('${fx.desc} – radioNum', () {
        final parsed = parseRawFrame(h(fx.rawHex));
        expect(parsed, isNotNull);
        expect(parsed!.radioNum, equals(fx.radioNum));
      });

      test('${fx.desc} – isTechFrame', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        expect(isTechFrame(parsed.mBytes), isTrue);
      });

      test('${fx.desc} – blockData[0]=CI=0xA2', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        expect(parsed.blockData[0], equals(0xA2));
      });
    }
  });

  group('parseRawFrame – Techem HCA', () {
    for (final fx in _techHca) {
      test('${fx.desc} – radioNum', () {
        final parsed = parseRawFrame(h(fx.rawHex));
        expect(parsed, isNotNull);
        expect(parsed!.radioNum, equals(fx.radioNum));
      });

      test('${fx.desc} – blockData[0]=CI=0xA0', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        expect(parsed.blockData[0], equals(0xA0));
      });
    }
  });

  // ── parseRawFrame – edge cases ────────────────────────────────────────────
  group('parseRawFrame – edge cases', () {
    test('returns null for short frame', () {
      expect(parseRawFrame(h('ff6444')), isNull);
    });

    test('returns null for wrong SOF', () {
      expect(parseRawFrame(Uint8List(20)), isNull);
    });
  });

  // ── buildIv ───────────────────────────────────────────────────────────────
  group('buildIv', () {
    test('structure: M(2)+A(6)+tplAcc×8', () {
      final m = h('0106');
      final a = h('454968020507');
      final iv = buildIv(m, a, 0xE9);
      expect(iv.length, equals(16));
      expect(iv.sublist(0, 2), equals(m));
      expect(iv.sublist(2, 8), equals(a));
      expect(iv.sublist(8), equals(Uint8List.fromList(List.filled(8, 0xE9))));
    });

    for (final fx in _apa162) {
      test('${fx.desc} – iv matches fixture', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        final tplAcc = parsed.blockData[1]; // CI=7A at [0], TPL_ACC at [1]
        final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
        expect(iv.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
            equals(fx.ivHex));
      });
    }
  });

  // ── decryptCbc – Apator 162 (zero key) ────────────────────────────────────
  group('decryptCbc – Apator 162 (zero key)', () {
    for (final fx in _apa162) {
      test('${fx.desc} – plaintext prefix = ${fx.plaintextPrefix}', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        final bd = parsed.blockData;
        final tplAcc = bd[1];
        final tplCfg = (bd[4] << 8) | bd[3];
        final nEnc = (tplCfg >> 4) & 0x0F;
        final encEnd = nEnc > 0
            ? (5 + nEnc * 16).clamp(0, bd.length)
            : bd.length;
        final enc = bd.sublist(5, encEnd);
        final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
        final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
        final pt = decryptCbc(zeroKey(), iv, Uint8List.fromList(encAligned));

        expect(pt, isNotNull);
        expect(pt!.length, greaterThanOrEqualTo(4));
        final prefix =
            pt.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        expect(prefix, equals(fx.plaintextPrefix));
      });
    }
  });

  // ── decryptCbc – Apator ELL (real key) ────────────────────────────────────
  group('decryptCbc – Apator ELL (real key)', () {
    for (final fx in _apaEll) {
      test('${fx.desc} – plaintext prefix = ${fx.plaintextPrefix}', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        final bd = parsed.blockData;
        // ELL: bd[0]=8C bd[3]=7A bd[4]=TPL_ACC bd[6..7]=Config
        final tplAcc = bd[4];
        final tplCfg = (bd[7] << 8) | bd[6];
        final nEnc = (tplCfg >> 4) & 0x0F;
        final encEnd = nEnc > 0
            ? (8 + nEnc * 16).clamp(0, bd.length)
            : bd.length;
        final enc = bd.sublist(8, encEnd);
        final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
        final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
        final key = List<int>.from(h(fx.aesKey));
        final pt = decryptCbc(key, iv, Uint8List.fromList(encAligned));

        expect(pt, isNotNull);
        final prefix =
            pt!.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        expect(prefix, equals(fx.plaintextPrefix));
      });
    }
  });

  // ── decryptCbc – edge cases ───────────────────────────────────────────────
  group('decryptCbc – edge cases', () {
    test('returns null for empty ciphertext', () {
      expect(decryptCbc(zeroKey(), Uint8List(16), Uint8List(0)), isNull);
    });

    test('returns null for unaligned ciphertext', () {
      expect(decryptCbc(zeroKey(), Uint8List(16), Uint8List(15)), isNull);
    });
  });

  // ── isApa162Payload / parseApa162Payload ──────────────────────────────────
  group('isApa162Payload + parseApa162Payload', () {
    for (final fx in _apa162) {
      test('${fx.desc} – is Apator162 payload', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        final bd = parsed.blockData;
        final tplAcc = bd[1];
        final tplCfg = (bd[4] << 8) | bd[3];
        final nEnc = (tplCfg >> 4) & 0x0F;
        final encEnd = nEnc > 0 ? (5 + nEnc * 16).clamp(0, bd.length) : bd.length;
        final enc = bd.sublist(5, encEnd);
        final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
        final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
        final pt = decryptCbc(zeroKey(), iv, Uint8List.fromList(encAligned))!;

        expect(isApa162Payload(Uint8List.fromList(pt)), isTrue);
      });

      test('${fx.desc} – volume = ${fx.volumeM3} m³', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        final bd = parsed.blockData;
        final tplAcc = bd[1];
        final tplCfg = (bd[4] << 8) | bd[3];
        final nEnc = (tplCfg >> 4) & 0x0F;
        final encEnd = nEnc > 0 ? (5 + nEnc * 16).clamp(0, bd.length) : bd.length;
        final enc = bd.sublist(5, encEnd);
        final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
        final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
        final pt = decryptCbc(zeroKey(), iv, Uint8List.fromList(encAligned))!;

        final result = parseApa162Payload(Uint8List.fromList(pt));
        expect(result.totalM3, isNotNull);
        expect(result.totalM3!, closeTo(fx.volumeM3, 0.001));
      });
    }

    test('returns false for OMS payload (2F 2F, no 0F)', () {
      expect(isApa162Payload(h('2f2f04131234')), isFalse);
    });
  });

  // ── parseOmsPayload – Apator ELL ──────────────────────────────────────────
  group('parseOmsPayload – Apator ELL', () {
    for (final fx in _apaEll) {
      test('${fx.desc} – volume = ${fx.volumeM3} m³', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        final bd = parsed.blockData;
        final tplAcc = bd[4];
        final tplCfg = (bd[7] << 8) | bd[6];
        final nEnc = (tplCfg >> 4) & 0x0F;
        final encEnd = nEnc > 0 ? (8 + nEnc * 16).clamp(0, bd.length) : bd.length;
        final enc = bd.sublist(8, encEnd);
        final encAligned = enc.sublist(0, (enc.length ~/ 16) * 16);
        final iv = buildIv(parsed.mBytes, parsed.aBytes, tplAcc);
        final key = List<int>.from(h(fx.aesKey));
        final pt = decryptCbc(key, iv, Uint8List.fromList(encAligned))!;

        final oms = parseOmsPayload(Uint8List.fromList(pt));
        expect(oms.volumeM3, isNotNull);
        expect(oms.volumeM3!, closeTo(fx.volumeM3, 0.001));
      });
    }
  });

  // ── parseTechWater ────────────────────────────────────────────────────────
  group('parseTechWater – Techem MK Radio 3', () {
    for (final fx in _techWater) {
      test('${fx.desc} – prev=${fx.prevM3} curr=${fx.currM3} total=${fx.totalM3} m³', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        final result = parseTechWater(parsed.blockData);
        expect(result, isNotNull);
        expect(result!.prevM3, closeTo(fx.prevM3, 0.05));
        expect(result.currM3, closeTo(fx.currM3, 0.05));
        expect(result.totalM3, closeTo(fx.totalM3, 0.1));
      });
    }

    test('returns null for short blockData', () {
      expect(parseTechWater(h('a2010203')), isNull);
    });
  });

  // ── parseTechHca ──────────────────────────────────────────────────────────
  group('parseTechHca – Techem FHKV Data III', () {
    for (final fx in _techHca) {
      test('${fx.desc} – prev=${fx.prevHca} curr=${fx.currHca}', () {
        final parsed = parseRawFrame(h(fx.rawHex))!;
        final result = parseTechHca(parsed.blockData, dllVersion: 0x69);
        expect(result, isNotNull);
        expect(result!.prevHca, equals(fx.prevHca));
        expect(result.currHca, equals(fx.currHca));
      });
    }

    test('returns null for short blockData', () {
      expect(parseTechHca(h('a001020304050607080910')), isNull);
    });
  });

  // ── decodeAlarms ──────────────────────────────────────────────────────────
  group('decodeAlarms', () {
    test('null word → empty list', () {
      expect(decodeAlarms(null), isEmpty);
    });

    test('zero word → [OK]', () {
      expect(decodeAlarms(0), equals(['OK']));
    });

    test('bit 11 → Water leak', () {
      expect(decodeAlarms(1 << 11), contains('Water leak'));
    });

    test('bit 8 → Low battery', () {
      expect(decodeAlarms(1 << 8), contains('Low battery'));
    });
  });
}
