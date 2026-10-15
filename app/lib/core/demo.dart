import 'device.dart';

/// Demo-Raum wie im Prototyp, damit die App ohne Server ausprobiert werden kann.
List<Device> demoDevices() => [
      Device(id: 'climate.klima', kind: DeviceKind.climate, name: 'Klimaanlage')
        ..on = true
        ..target = 22
        ..current = 24.1
        ..humidity = 48
        ..hvacMode = 'cool'
        ..hvacModes = const ['cool', 'heat', 'auto', 'dry', 'fan_only']
        ..fanMode = 'auto'
        ..fanModes = const ['auto', 'quiet', 'low', 'medium', 'high', 'turbo']
        ..swingMode = 'vertical'
        ..swingModes = const ['off', 'vertical']
        ..preset = 'none'
        ..presets = const ['none', 'eco'],
      Device(id: 'light.decke', kind: DeviceKind.light, name: 'Deckenlicht')
        ..on = true
        ..bri = 80
        ..hasColor = true
        ..hasKelvin = true
        ..lightMode = 'white'
        ..kelvin = 3000,
      Device(id: 'light.steh', kind: DeviceKind.light, name: 'Stehlampe')
        ..bri = 45
        ..hasColor = true
        ..hasKelvin = true
        ..lightMode = 'color'
        ..hue = 28
        ..sat = .8,
      Device(id: 'light.led_tv', kind: DeviceKind.light, name: 'LED-Streifen TV')
        ..on = true
        ..bri = 55
        ..hasColor = true
        ..hasKelvin = true
        ..lightMode = 'color'
        ..hue = 265
        ..sat = .7,
      Device(id: 'light.lese', kind: DeviceKind.light, name: 'Leselampe')
        ..bri = 70
        ..kelvin = 2700,
      Device(id: 'cover.rollo', kind: DeviceKind.cover, name: 'Rollo Terrasse'),
      Device(id: 'media_player.sonos', kind: DeviceKind.media, name: 'Sonos')
        ..volume = 35
        ..title = 'Kerala'
        ..artist = 'Bonobo',
      Device(id: 'scene.filmabend', kind: DeviceKind.scene, name: 'Filmabend'),
      Device(id: 'lock.haustuer', kind: DeviceKind.lock, name: 'Haustür')..on = true,
    ];

/// Was die Demo-Szene "Filmabend" schaltet.
void applyDemoScene(List<Device> all) {
  for (final d in all) {
    switch (d.id) {
      case 'light.decke' || 'light.lese':
        d.on = false;
      case 'light.steh':
        d
          ..on = true
          ..bri = 20
          ..lightMode = 'color'
          ..hue = 28
          ..sat = .8;
      case 'light.led_tv':
        d
          ..on = true
          ..bri = 40
          ..lightMode = 'color'
          ..hue = 240
          ..sat = .75;
      case 'cover.rollo':
        d.position = 0;
    }
  }
}
