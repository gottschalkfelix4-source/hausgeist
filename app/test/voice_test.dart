import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hausgeist/core/home_store.dart';
import 'package:hausgeist/voice/audio_tools.dart';
import 'package:hausgeist/voice/voice_orb.dart';
import 'package:hausgeist/voice/voice_service.dart';
import 'package:hausgeist/voice/wake_word.dart';

/// 100 ms Ton (Sprache) bzw. leises Rauschen (Pause).
Int16List block({double amp = 0}) {
  final r = math.Random(1);
  return Int16List.fromList([
    for (var i = 0; i < sampleRate ~/ 10; i++)
      (amp * 32767 * math.sin(2 * math.pi * 220 * i / sampleRate) + (r.nextDouble() - .5) * 40).round(),
  ]);
}

void main() {
  group('Audio', () {
    test('PCM16 über Blockgrenzen mit ungerader Länge', () {
      final d = Pcm16Decoder();
      final bytes = Uint8List.fromList([0x01, 0x00, 0xFF, 0xFF, 0x00, 0x80]);
      expect(d.add(bytes.sublist(0, 3)), [1]);
      expect(d.add(bytes.sublist(3)), [-1, -32768]);
    });

    test('Pegel in dBFS', () {
      expect(levelDb(Int16List(160)), -100);
      expect(levelDb(Int16List.fromList(List.filled(160, 32767))), closeTo(0, .01));
      expect(levelDb(block(amp: .1)), closeTo(-23, 1)); // Sinus: -3 dB unter Spitze
      expect(levelToUnit(-80), 0);
      expect(levelToUnit(0), 1);
    });

    test('lautester Wert der letzten Sekunde', () {
      final l = RecentLevels();
      l.add(block(amp: .5));
      for (var i = 0; i < 5; i++) {
        l.add(block());
      }
      expect(l.peak, greaterThan(-10));
      for (var i = 0; i < 12; i++) {
        l.add(block());
      }
      expect(l.peak, lessThan(-50));
    });

    test('Ende nach Sprache und kurzer Pause', () {
      final e = Endpointer();
      for (var i = 0; i < 5; i++) {
        expect(e.add(block()), isNull);
      }
      for (var i = 0; i < 10; i++) {
        expect(e.add(block(amp: .2)), isNull);
      }
      EndReason? end;
      var quiet = 0;
      while (end == null) {
        end = e.add(block());
        quiet++;
      }
      expect(end, EndReason.silence);
      expect(quiet, 9);
    });

    test('nichts gesagt / zu lang / Signalton zählt nicht', () {
      final silent = Endpointer();
      EndReason? end;
      var n = 0;
      while (end == null) {
        end = silent.add(block());
        n++;
      }
      expect((end, n), (EndReason.nothingSaid, 50));

      final long = Endpointer();
      end = null;
      n = 0;
      while (end == null) {
        end = long.add(block(amp: .3));
        n++;
      }
      expect((end, n), (EndReason.maxLength, 120));

      final chime = Endpointer()..holdOff(5);
      for (var i = 0; i < 5; i++) {
        expect(chime.add(block(amp: .5)), isNull);
      }
      expect(chime.spoke, isFalse);
    });

    test('WAV-Kopf', () {
      final w = wavBytes(Int16List.fromList([1, 2, 3]));
      expect(w.length, 50);
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(ByteData.sublistView(w).getUint32(24, Endian.little), sampleRate);
      expect(chime().length, greaterThan(10000));
    });
  });

  test('Aktivierungswort vom Server', () {
    final w = WakeConfig.fromJson({'enabled': true, 'words': ['Computer'], 'keywords': '▁COMP U TER #0.2 @Computer'});
    expect(w.active, isTrue);
    expect(w, WakeConfig.fromJson({'enabled': true, 'words': ['Computer'], 'keywords': '▁COMP U TER #0.2 @Computer'}));
    expect(WakeConfig.fromJson({'enabled': true, 'keywords': ''}).active, isFalse);
    expect(WakeConfig.fromJson({}), WakeConfig.off);
  });

  test('Kugel reagiert auf die Stimme', () {
    final s = OrbState();
    for (var i = 0; i < 30; i++) {
      s.step(1 / 60, VoicePhase.listening, .8);
    }
    expect(s.level, greaterThan(.7));
    for (var i = 0; i < 120; i++) {
      s.step(1 / 60, VoicePhase.thinking, 0);
    }
    expect(s.level, lessThan(.05));
    expect(s.think, greaterThan(.9));
  });

  testWidgets('Demo: Mikrofon antippen öffnet die Kugel bis zur Antwort', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final store = HomeStore(null);
    await store.start();
    final voice = VoiceService(store)..start();
    addTearDown(voice.dispose);
    await t.pumpWidget(MaterialApp(
      home: Stack(children: [
        Center(child: TextButton(onPressed: voice.activate, child: const Text('Mikro'))),
        Positioned.fill(child: VoiceOverlay(voice: voice)),
      ]),
    ));
    expect(voice.visible, isFalse);
    await t.tap(find.text('Mikro'));
    await t.pump(const Duration(milliseconds: 300));
    expect(voice.phase, VoicePhase.listening);
    expect(find.text('Ich höre zu …'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 1000));
    expect(voice.level.value, greaterThan(0));

    await t.pump(const Duration(milliseconds: 1600));
    expect(voice.phase, VoicePhase.thinking);
    expect(find.text('„Mach das Licht gemütlich“'), findsOneWidget);

    await t.pump(const Duration(milliseconds: 1400));
    expect(voice.phase, VoicePhase.speaking);
    expect(find.textContaining('30 Prozent'), findsOneWidget);
    expect(store.devices.firstWhere((d) => d.id == 'light.decke').bri, 30);

    await t.tap(find.byTooltip('Schließen'));
    await t.pump(const Duration(milliseconds: 600));
    expect(voice.phase, VoicePhase.idle);
    await t.pump(const Duration(seconds: 5));
  });
}
