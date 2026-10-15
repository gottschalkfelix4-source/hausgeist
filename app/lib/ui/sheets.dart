import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/device.dart';
import '../core/home_store.dart';
import 'controls.dart';
import 'theme.dart';

/// Detail-Fenster einer Kachel, über dem verschwommenen Raum.
Future<void> openDeviceSheet(BuildContext context, HomeStore store, Device d) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Schließen',
    barrierColor: const Color(0x4D000000),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, _) => BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: Center(child: DeviceSheet(store: store, device: d)),
    ),
    transitionBuilder: (ctx, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
          scale: Tween(begin: .94, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)), child: child),
    ),
  );
}

class DeviceSheet extends StatelessWidget {
  const DeviceSheet({super.key, required this.store, required this.device});
  final HomeStore store;
  final Device device;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final p = Palette.of(context);
    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: p.text),
        child: Container(
          width: math.min(780, size.width - 32),
          constraints: BoxConstraints(maxHeight: size.height - 32),
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
          decoration: BoxDecoration(color: p.sheet, borderRadius: BorderRadius.circular(28)),
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
                _Head(store: store, device: device),
                const SizedBox(height: 18),
                _body(),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() => switch (device.kind) {
        DeviceKind.light => _LightBody(store: store, d: device),
        DeviceKind.climate => _ClimateBody(store: store, d: device),
        DeviceKind.cover => _CoverBody(store: store, d: device),
        DeviceKind.media => _MediaBody(store: store, d: device),
        _ => const SizedBox.shrink(),
      };
}

class _Head extends StatelessWidget {
  const _Head({required this.store, required this.device});
  final HomeStore store;
  final Device device;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = device;
    return Row(children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: d.isOn ? accentOf(d) : const Color(0x26FFFFFF), shape: BoxShape.circle),
        child: Icon(iconFor(d.id, d.name), color: Colors.white, size: 24),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
          Text(statusOf(d), style: TextStyle(fontSize: 13, color: p.textMuted)),
        ]),
      ),
      OnOffSwitch(value: d.isOn, onChanged: (_) => store.toggle(d)),
      const SizedBox(width: 12),
      RoundButton(onTap: () => Navigator.of(context).pop(), tooltip: 'Schließen', child: const Icon(Icons.close_rounded)),
    ]);
  }
}

/// Links der große Regler, rechts die Optionen. Schmal: untereinander.
class _Split extends StatelessWidget {
  const _Split({required this.left, required this.right});
  final Widget left;
  final List<Widget> right;

  @override
  Widget build(BuildContext context) {
    final col = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final w in right) Padding(padding: const EdgeInsets.only(bottom: 12), child: w),
    ]);
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 560) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [left, const SizedBox(width: 28), Expanded(child: col)]);
      }
      return Column(children: [left, const SizedBox(height: 20), col]);
    });
  }
}

// ---------- Licht ----------

const _swatches = <(int?, double?, double?)>[
  (2200, null, null), (2700, null, null), (4000, null, null), (6500, null, null),
  (null, 0, .85), (null, 28, .9), (null, 50, .8), (null, 140, .6), (null, 200, .75), (null, 265, .7), (null, 320, .6),
];

class _LightBody extends StatelessWidget {
  const _LightBody({required this.store, required this.d});
  final HomeStore store;
  final Device d;

  @override
  Widget build(BuildContext context) {
    final colorMode = d.hasColor && (d.lightMode == 'color' || !d.hasKelvin);
    final swatches = _swatches.where((s) => s.$1 != null ? d.hasKelvin : d.hasColor).toList();
    final right = <Widget>[
      if (d.hasColor && d.hasKelvin)
        Segmented<String>(
          options: const [('color', 'Farbe'), ('white', 'Weißtöne')],
          selected: d.lightMode,
          onSelect: (m) => store.setLightMode(d, m),
        ),
      if (colorMode)
        Center(child: ColorWheel(hue: d.hue, sat: d.sat, onChanged: (h, s) => store.setColor(d, h, s)))
      else if (d.hasKelvin)
        KelvinBar(kelvin: d.kelvin, min: d.minKelvin, max: d.maxKelvin, onChanged: (k) => store.setKelvin(d, k)),
      if (swatches.isNotEmpty) ...[
        const SectionLabel('Favoriten'),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final s in swatches) _Swatch(store: store, d: d, s: s),
        ]),
      ],
      if (d.dimmable) ...[
        const SectionLabel('Helligkeit'),
        ChoiceChips<int>(
          options: const [(100, 'Hell', null), (60, 'Normal', null), (30, 'Gemütlich', null), (5, 'Nachtlicht', null)],
          selected: d.on ? d.bri : null,
          onSelect: (v) => store.setLevel(d, v / 100),
        ),
      ],
    ];
    if (!d.dimmable) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: right);
    return _Split(
      left: VSlider(
        label: 'Helligkeit',
        value: d.on ? d.bri / 100 : 0,
        fill: d.on ? LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [lightColor(d), Colors.white]) : null,
        onChanged: (v) => store.setLevel(d, v),
      ),
      right: right,
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.store, required this.d, required this.s});
  final HomeStore store;
  final Device d;
  final (int?, double?, double?) s;

  @override
  Widget build(BuildContext context) {
    final (k, h, sat) = s;
    final selected = k != null
        ? d.lightMode == 'white' && d.kelvin == k
        : d.lightMode == 'color' && (d.hue - h!).abs() < 1 && (d.sat - sat!).abs() < .01;
    return Semantics(
      button: true,
      selected: selected,
      label: k != null ? '$k Kelvin' : 'Farbe',
      child: GestureDetector(
        onTap: () => k != null ? store.setKelvin(d, k) : store.setColor(d, h!, sat!),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: k != null ? kelvinColor(k) : hsvColor(h!, sat!),
            shape: BoxShape.circle,
            border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
          ),
        ),
      ),
    );
  }
}

// ---------- Klima ----------

class _ClimateBody extends StatelessWidget {
  const _ClimateBody({required this.store, required this.d});
  final HomeStore store;
  final Device d;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final mode = climateModes[d.hvacMode];
    final info = [
      if (d.current != null) 'Innen ${temp(d.current!)}',
      if (d.humidity != null) '${d.humidity!.round()} % Feuchte',
    ].join(' · ');
    final left = Column(mainAxisSize: MainAxisSize.min, children: [
      ThermostatDial(
        value: d.target,
        min: d.minTemp,
        max: d.maxTemp,
        color: d.on ? (mode?.color ?? Palette.ok) : const Color(0x55FFFFFF),
        onChanged: (v) => store.setTarget(d, v),
        center: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(d.on ? (mode?.verb ?? d.hvacMode) : 'Aus', style: TextStyle(fontSize: 13, color: p.textMuted)),
          Text(temp(d.target).replaceAll(' °C', '°'),
              style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w500, height: 1.1, fontFeatures: [FontFeature.tabularFigures()])),
          if (info.isNotEmpty) Text(info, style: TextStyle(fontSize: 13, color: p.textMuted)),
        ]),
      ),
      const SizedBox(height: 10),
      Row(mainAxisSize: MainAxisSize.min, children: [
        RoundButton(size: 52, tooltip: 'Kälter', onTap: () => store.setTarget(d, d.target - d.tempStep), child: const Icon(Icons.remove_rounded)),
        const SizedBox(width: 14),
        RoundButton(size: 52, tooltip: 'Wärmer', onTap: () => store.setTarget(d, d.target + d.tempStep), child: const Icon(Icons.add_rounded)),
      ]),
    ]);
    return _Split(left: left, right: [
      const SectionLabel('Modus'),
      ChoiceChips<String>(
        options: [
          for (final m in d.hvacModes) (m, climateModes[m]?.label ?? m, climateModes[m]?.color),
        ],
        selected: d.on ? d.hvacMode : null,
        onSelect: (m) => store.setClimateMode(d, m),
      ),
      if (d.fanModes.isNotEmpty) ...[
        const SectionLabel('Lüfter'),
        Segmented<String>(
          options: [for (final f in d.fanModes) (f, fanLabel(f))],
          selected: d.fanMode,
          onSelect: (f) => store.setFan(d, f),
        ),
      ],
      if (d.swingModes.isNotEmpty || d.hasEco)
        Column(children: [
          if (d.swingModes.isNotEmpty) OptionRow(label: 'Lamellen schwenken', value: d.swing, onChanged: (v) => store.setSwing(d, v)),
          if (d.hasEco) OptionRow(label: 'Eco-Modus', value: d.eco, onChanged: (v) => store.setEco(d, v)),
        ]),
    ]);
  }
}

// ---------- Rollo ----------

class _CoverBody extends StatelessWidget {
  const _CoverBody({required this.store, required this.d});
  final HomeStore store;
  final Device d;

  @override
  Widget build(BuildContext context) => _Split(
        left: VSlider(label: 'Position', value: d.position / 100, onChanged: (v) => store.setLevel(d, v)),
        right: [
          const SectionLabel('Steuerung'),
          ChoiceChips<int>(
            options: const [(100, 'Öffnen', null), (50, 'Halb', null), (0, 'Schließen', null)],
            selected: d.position,
            onSelect: (v) => store.setLevel(d, v / 100),
          ),
        ],
      );
}

// ---------- Medien ----------

class _MediaBody extends StatelessWidget {
  const _MediaBody({required this.store, required this.d});
  final HomeStore store;
  final Device d;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return _Split(
      left: VSlider(label: 'Lautstärke', value: d.volume / 100, onChanged: (v) => store.setLevel(d, v)),
      right: [
        Row(children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(colors: [Color(0xFFE07A5F), Color(0xFF3D405B)]),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.title ?? 'Nichts in Wiedergabe', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              if (d.artist != null) Text(d.artist!, style: TextStyle(color: p.textMuted)),
            ]),
          ),
        ]),
        Wrap(spacing: 8, children: [
          PillButton(onTap: () => store.media(d, 'previous'), child: const Icon(Icons.skip_previous_rounded)),
          PillButton(
            selected: d.on,
            onTap: () => store.media(d, 'play_pause'),
            child: Icon(d.on ? Icons.pause_rounded : Icons.play_arrow_rounded),
          ),
          PillButton(onTap: () => store.media(d, 'next'), child: const Icon(Icons.skip_next_rounded)),
        ]),
      ],
    );
  }
}
