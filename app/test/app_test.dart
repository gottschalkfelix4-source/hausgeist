import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hausgeist/core/api.dart';
import 'package:hausgeist/core/config.dart';
import 'package:hausgeist/core/device.dart';
import 'package:hausgeist/core/home_store.dart';
import 'package:hausgeist/display/motion_detector.dart';
import 'package:hausgeist/ui/home_screen.dart';
import 'package:hausgeist/ui/setup_screen.dart';
import 'package:hausgeist/voice/voice_service.dart';

void main() {
  group('Gerät aus Home Assistant', () {
    test('Farblicht', () {
      final d = Device.fromHa({
        'entity_id': 'light.steh',
        'state': 'on',
        'attributes': {
          'friendly_name': 'Stehlampe',
          'brightness': 128,
          'supported_color_modes': ['color_temp', 'hs'],
          'color_mode': 'hs',
          'hs_color': [28, 80],
        },
      })!;
      expect(d.name, 'Stehlampe');
      expect(d.bri, 50);
      expect(d.hasColor && d.hasKelvin, isTrue);
      expect(d.lightMode, 'color');
      expect(d.sat, closeTo(.8, 1e-9));
      expect(statusOf(d), '50 % · Farbe');
    });

    test('Klima aus behält den letzten Modus', () {
      final d = Device.fromHa({
        'entity_id': 'climate.wz',
        'state': 'off',
        'attributes': {'hvac_modes': ['off', 'heat', 'cool'], 'temperature': 21.5, 'current_temperature': 23},
      })!;
      expect(d.on, isFalse);
      expect(d.hvacModes, ['heat', 'cool']);
      expect(statusOf(d), 'Aus');
      expect(temp(d.target), '21,5 °C');
    });

    test('unbekannte Domains werden ignoriert', () {
      expect(Device.fromHa({'entity_id': 'automation.x', 'state': 'on'}), isNull);
    });
  });

  group('Bewegungserkennung', () {
    Float32List frame(double base) => Float32List.fromList(List.filled(32 * 24, base));

    test('Licht an (alles gleich heller) ist keine Bewegung', () {
      expect(MotionDetector.changedArea(frame(60), frame(140)), 0);
    });

    test('Person nah vor dem Tablet ändert viel, weit hinten wenig', () {
      final near = frame(80)..fillRange(0, 300, 200);
      final far = frame(80)..fillRange(0, 20, 200);
      expect(MotionDetector.changedArea(frame(80), near), greaterThan(.2));
      expect(MotionDetector.changedArea(frame(80), far), lessThan(.2));
    });
  });

  group('Oberfläche (Demo)', () {
    late HomeStore store;

    Future<void> pump(WidgetTester t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      store = HomeStore(null);
      await store.start();
      await t.pumpWidget(MaterialApp(home: HomeScreen(store: store, voice: VoiceService(store), onSettings: () {})));
    }

    testWidgets('zeigt Raum und Geräte', (t) async {
      await pump(t);
      expect(find.text('Wohnzimmer'), findsOneWidget);
      expect(find.text('Deckenlicht'), findsOneWidget);
      expect(find.text('Klima und Licht'), findsOneWidget);
    });

    testWidgets('Symbol antippen schaltet, Kachel antippen öffnet Details', (t) async {
      await pump(t);
      final steh = store.devices.firstWhere((d) => d.id == 'light.steh');
      expect(steh.on, isFalse);
      await t.tap(find.bySemanticsLabel('Stehlampe ein- oder ausschalten'));
      await t.pump();
      expect(steh.on, isTrue);

      await t.tap(find.text('Deckenlicht'));
      await t.pumpAndSettle();
      expect(find.text('FAVORITEN'), findsOneWidget);
      expect(find.text('Weißtöne'), findsOneWidget);
    });

    testWidgets('über die Kachel wischen dimmt', (t) async {
      await pump(t);
      final decke = store.devices.firstWhere((d) => d.id == 'light.decke');
      final before = decke.bri;
      await t.drag(find.text('Deckenlicht'), const Offset(-120, 0));
      await t.pump();
      expect(decke.bri, lessThan(before));
    });
  });

  group('Update-Hinweis', () {
    test('Versionen vergleichen', () {
      expect(isNewerVersion('v0.3.0', '0.2.0'), isTrue);
      expect(isNewerVersion('0.10.0', '0.9.9'), isTrue);
      expect(isNewerVersion('v0.2.0', '0.2.0'), isFalse);
      expect(isNewerVersion('0.1.9', '0.2.0'), isFalse);
      expect(isNewerVersion('1.0', '0.9.0+5'), isTrue);
    });
  });

  group('Einrichtung', () {
    Future<void> pumpSetup(WidgetTester t, [AppConfig initial = const AppConfig()]) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      await t.pumpWidget(MaterialApp(home: SetupScreen(initial: initial, onDone: (_) {})));
    }

    testWidgets('Kopplungscode ist der Standardweg', (t) async {
      await pumpSetup(t);
      expect(find.text('Kopplungscode'), findsOneWidget);
      expect(find.text('Tablet-Token'), findsNothing);
      await t.enterText(find.byType(TextField).first, 'http://hausgeist:8080');
      await t.enterText(find.byType(TextField).last, '12ab3');
      await t.tap(find.text('Verbinden'));
      await t.pump();
      expect(find.text('Der Kopplungscode hat 6 Ziffern.'), findsOneWidget);

      await t.tap(find.text('Erweitert: Token eingeben'));
      await t.pump();
      expect(find.text('Tablet-Token'), findsOneWidget);
    });

    testWidgets('vorhandener Token öffnet direkt die erweiterte Ansicht', (t) async {
      await pumpSetup(t, const AppConfig(server: 'http://x', token: 'abc'));
      expect(find.text('Tablet-Token'), findsOneWidget);
    });
  });
}
