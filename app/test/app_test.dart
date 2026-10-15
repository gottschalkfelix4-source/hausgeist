import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smarthome_wall/core/device.dart';
import 'package:smarthome_wall/core/home_store.dart';
import 'package:smarthome_wall/display/motion_detector.dart';
import 'package:smarthome_wall/ui/home_screen.dart';
import 'package:smarthome_wall/voice/voice_service.dart';

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
}
