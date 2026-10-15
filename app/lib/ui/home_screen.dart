import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../core/device.dart';
import '../core/home_store.dart';
import '../voice/voice_service.dart';
import 'sheets.dart';
import 'theme.dart';
import 'tiles.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.store, required this.voice, required this.onSettings});
  final HomeStore store;
  final VoiceService voice;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Wallpaper(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: Listenable.merge([store, voice]),
            builder: (context, _) => Stack(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _Header(store: store, onSettings: onSettings),
                  const SizedBox(height: 16),
                  Expanded(child: SingleChildScrollView(child: _Grid(store: store))),
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerRight, child: _MicButton(voice: voice)),
                ]),
              ),
              if (voice.bubble != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 84,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Glass(
                        color: const Color(0x55000000),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                        child: Text(voice.bubble!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15)),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------- Kopfzeile ----------

const _weekdays = ['Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag', 'Sonntag'];
const _months = ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'];

class _Header extends StatelessWidget {
  const _Header({required this.store, required this.onSettings});
  final HomeStore store;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final ds = store.devices;
    final climate = ds.where((d) => d.kind == DeviceKind.climate).firstOrNull;
    final lights = ds.where((d) => d.kind == DeviceKind.light).toList();
    final lock = ds.where((d) => d.kind == DeviceKind.lock).firstOrNull;
    final tempSensor = ds.where((d) => d.kind == DeviceKind.sensor && d.deviceClass == 'temperature').firstOrNull;
    final inside = climate?.current ?? double.tryParse(tempSensor?.stateText ?? '');
    final onCount = store.tiles.where((d) => d.isOn).length;
    final sub = [
      if (store.devices.isNotEmpty) '$onCount ${onCount == 1 ? 'Gerät' : 'Geräte'} an',
      if (inside != null) 'Innen ${temp(inside)}',
      if (!store.connected) store.error != null ? 'Keine Verbindung, neuer Versuch …' : 'Verbinde …',
      if (store.demo) 'Demo',
    ].join(' · ');

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(store.room, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w700, height: 1, letterSpacing: -.3)),
          const SizedBox(height: 6),
          Text(sub, style: TextStyle(fontSize: 14, color: p.textMuted)),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: [
            if (climate != null)
              _Stat(
                  icon: Icons.thermostat_rounded,
                  title: 'Klima',
                  value: climate.on ? '${climateModes[climate.hvacMode]?.label ?? climate.hvacMode} · ${temp(climate.target)}' : 'Aus'),
            if (lights.isNotEmpty)
              _Stat(
                  icon: Icons.lightbulb_outline_rounded,
                  title: 'Licht',
                  value: lights.any((l) => l.on) ? '${lights.where((l) => l.on).length} an' : 'Alle aus'),
            if (lock != null) _Stat(icon: Icons.lock_outline_rounded, title: 'Sicherheit', value: lock.on ? 'Verriegelt' : '${lock.name} offen'),
          ]),
        ]),
      ),
      // Lange auf die Uhr drücken öffnet die Einrichtung.
      GestureDetector(onLongPress: onSettings, child: const _Clock()),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.title, required this.value});
  final IconData icon;
  final String title, value;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Glass(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: p.text),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          Text(value, style: TextStyle(fontSize: 12, color: p.textMuted)),
        ]),
      ]),
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late Timer _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 5), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = _now;
    String two(int v) => v.toString().padLeft(2, '0');
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text('${two(n.hour)}:${two(n.minute)}',
          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w500, height: 1, fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(height: 6),
      Text('${_weekdays[n.weekday - 1]}, ${n.day}. ${_months[n.month - 1]}',
          style: TextStyle(fontSize: 13, color: Palette.of(context).textMuted)),
    ]);
  }
}

// ---------- Kachel-Raster ----------

class _Grid extends StatelessWidget {
  const _Grid({required this.store});
  final HomeStore store;

  @override
  Widget build(BuildContext context) {
    final tiles = store.tiles;
    if (tiles.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Text(
          store.connected ? 'Diesem Raum sind noch keine Geräte zugewiesen.' : '',
          textAlign: TextAlign.center,
          style: TextStyle(color: Palette.of(context).textMuted),
        ),
      );
    }
    final main = tiles.where((d) => d.kind == DeviceKind.climate || d.kind == DeviceKind.light).toList();
    final rest = tiles.where((d) => !main.contains(d)).toList();
    void open(Device d) => openDeviceSheet(context, store, d);

    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 760 ? 4 : 2;
      Widget section(String t) => StaggeredGridTile.extent(
            crossAxisCellCount: cols,
            mainAxisExtent: 26,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          );
      Widget tile(Device d) => d.kind == DeviceKind.climate
          ? StaggeredGridTile.extent(
              crossAxisCellCount: 2,
              mainAxisExtent: 172,
              child: ClimateTile(device: d, store: store, onOpen: open),
            )
          : StaggeredGridTile.extent(
              crossAxisCellCount: 1,
              mainAxisExtent: 80,
              child: DeviceTile(device: d, store: store, onOpen: open),
            );
      return StaggeredGrid.count(
        crossAxisCount: cols,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        children: [
          if (main.isNotEmpty) section('Klima und Licht'),
          ...main.map(tile),
          if (rest.isNotEmpty) section(main.isEmpty ? 'Geräte' : 'Weitere Geräte'),
          ...rest.map(tile),
        ],
      );
    });
  }
}

// ---------- Sprachassistent ----------

class _MicButton extends StatelessWidget {
  const _MicButton({required this.voice});
  final VoiceService voice;

  Future<void> _typeText(BuildContext context) async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF26262E),
        title: const Text('Was soll ich tun?', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'z. B. Mach das Licht gemütlich'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Senden')),
        ],
      ),
    );
    if (text != null) await voice.sendText(text);
  }

  @override
  Widget build(BuildContext context) {
    final listening = voice.phase == VoicePhase.listening;
    return Semantics(
      button: true,
      label: 'Sprachassistent. Halten zum Sprechen, antippen zum Schreiben.',
      child: GestureDetector(
        onTap: () => _typeText(context),
        onLongPressStart: (_) => voice.startListening(),
        onLongPressEnd: (_) => voice.stopListening(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: listening ? Colors.white : Palette.of(context).glass,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.mic_none_rounded, size: 20, color: listening ? const Color(0xFFFF3B30) : Palette.acc),
            const SizedBox(width: 10),
            Text(listening ? 'Loslassen zum Senden' : 'Halten zum Sprechen oder tippen',
                style: TextStyle(fontSize: 14, color: listening ? const Color(0xFF1D1D1F) : null)),
          ]),
        ),
      ),
    );
  }
}
