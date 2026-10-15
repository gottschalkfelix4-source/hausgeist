import 'package:smarthome_wall/display/display_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late DisplayController c;

  void advance(Duration d) {
    // sekundenweise vorspulen, wie der echte Ticker
    for (var i = 0; i < d.inSeconds; i++) {
      now = now.add(const Duration(seconds: 1));
      c.tick();
    }
  }

  void motionBurst({double area = 1}) {
    c.onCameraMotion(area: area);
    now = now.add(const Duration(milliseconds: 400));
    c.onCameraMotion(area: area);
  }

  setUp(() {
    now = DateTime(2026, 10, 15, 14); // Nachmittag, keine Nacht
    c = DisplayController(const DisplaySettings(), clock: () => now);
  });

  test('dimmt nach dimAfter, bleibt aber an solange jemand im Raum ist', () {
    advance(const Duration(seconds: 31));
    expect(c.state, DisplayState.idle);
    for (var i = 0; i < 10; i++) {
      advance(const Duration(seconds: 60));
      motionBurst(area: 0.05); // Person bewegt sich hinten im Raum
    }
    expect(c.state, DisplayState.idle);
    expect(c.brightness, greaterThan(0));
  });

  test('gedimmt: Annäherung macht ohne Antippen wieder hell', () {
    advance(const Duration(seconds: 40));
    expect(c.state, DisplayState.idle);
    final dimmed = c.brightness;
    motionBurst(area: 0.4); // jemand kommt aufs Tablet zu
    expect(c.state, DisplayState.active);
    expect(c.brightness, greaterThan(dimmed));
    // bleibt hell, solange die Person davor steht und sich bewegt
    for (var i = 0; i < 5; i++) {
      advance(const Duration(seconds: 20));
      motionBurst(area: 0.3);
    }
    expect(c.state, DisplayState.active);
    // Person geht weg -> nach dimAfter wieder gedimmt
    advance(const Duration(seconds: 31));
    expect(c.state, DisplayState.idle);
  });

  test('geht aus, wenn niemand da ist und nichts bedient wird', () {
    advance(const Duration(seconds: 125));
    expect(c.state, DisplayState.off);
    expect(c.brightness, 0);
  });

  test('wacht bei Annäherung auf, aber nicht bei einem einzelnen Lichtwechsel', () {
    advance(const Duration(seconds: 125));
    now = now.add(const Duration(seconds: 5));
    c.onCameraMotion();
    expect(c.state, DisplayState.off);
    now = now.add(const Duration(seconds: 3));
    motionBurst();
    expect(c.state, DisplayState.active);
  });

  test('eigenes Display-Licht weckt sich nicht selbst', () {
    advance(const Duration(seconds: 120)); // geht genau jetzt aus
    expect(c.state, DisplayState.off);
    motionBurst(); // Bild ändert sich, weil das Display dunkel wurde
    expect(c.state, DisplayState.off);
  });

  test('bleibt nach dem Aufwachen mindestens minOnTime an', () {
    c = DisplayController(
      const DisplaySettings(
        dimAfter: Duration(seconds: 5),
        sleepAfter: Duration(seconds: 10),
        presenceHold: Duration(seconds: 10),
      ),
      clock: () => now,
    );
    advance(const Duration(seconds: 25)); // aus nach minOnTime (20 s)
    expect(c.state, DisplayState.off);
    c.onWakeSignal();
    c.onPresenceSensor(false);
    advance(const Duration(seconds: 15)); // leer + 15 s unbedient, aber erst 15 s an
    expect(c.state, DisplayState.idle);
    advance(const Duration(seconds: 6));
    expect(c.state, DisplayState.off);
  });

  test('Präsenzmelder hält das Display an, egal wie lange', () {
    c.onPresenceSensor(true);
    advance(const Duration(minutes: 30));
    expect(c.state, DisplayState.idle);
    c.onPresenceSensor(false);
    advance(const Duration(seconds: 60));
    expect(c.state, DisplayState.idle); // Haltezeit läuft noch
    advance(const Duration(seconds: 40));
    expect(c.state, DisplayState.off);
  });

  test('Berührung macht sofort volle Helligkeit', () {
    advance(const Duration(seconds: 40));
    final dimmed = c.brightness;
    c.onTouch();
    expect(c.state, DisplayState.active);
    expect(c.brightness, greaterThan(dimmed));
  });

  test('nachts gedeckelte Helligkeit und dunkles Design', () {
    now = DateTime(2026, 10, 15, 23);
    c.onAmbientLux(800);
    for (var i = 0; i < 20; i++) {
      c.onAmbientLux(800);
    }
    expect(c.brightness, lessThanOrEqualTo(0.15));
    expect(c.nightTheme, isTrue);
  });

  test('Umgebungslicht: hell -> heller, dunkel -> dunkler', () {
    for (var i = 0; i < 30; i++) {
      c.onAmbientLux(1000);
    }
    expect(c.brightness, greaterThan(0.9));
    for (var i = 0; i < 30; i++) {
      c.onAmbientLux(3);
    }
    expect(c.brightness, lessThan(0.3));
  });

  test('kleine Lichtschwankungen ändern die Helligkeit nicht', () {
    c.onAmbientLux(100);
    final b = c.brightness;
    c.onAmbientLux(130); // Wolke, Lampe im Nebenraum ...
    c.onAmbientLux(80);
    expect(c.brightness, b);
  });
}
