import 'package:flutter/material.dart';

import '../core/device.dart';
import '../core/home_store.dart';
import 'theme.dart';

/// Normale Kachel: Symbol antippen = ein/aus, Kachel antippen = Details, quer wischen = regeln.
class DeviceTile extends StatefulWidget {
  const DeviceTile({super.key, required this.device, required this.store, required this.onOpen});
  final Device device;
  final HomeStore store;
  final ValueChanged<Device> onOpen;

  @override
  State<DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<DeviceTile> {
  double _start = 0, _dx = 0;

  Device get d => widget.device;

  void _tap() {
    if (const {DeviceKind.scene, DeviceKind.lock, DeviceKind.toggle}.contains(d.kind)) {
      widget.store.toggle(d);
    } else {
      widget.onOpen(d);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final on = d.isOn;
    final acc = accentOf(d);
    final fill = switch (d.kind) {
      DeviceKind.light => d.on ? d.bri / 100 : 0.0,
      DeviceKind.cover => d.position / 100,
      _ => 0.0,
    };
    return LayoutBuilder(builder: (context, box) {
      return Semantics(
        button: true,
        label: '${d.name}, ${statusOf(d)}',
        child: GestureDetector(
          onTap: _tap,
          onHorizontalDragStart: d.adjustable
              ? (_) {
                  _start = d.level;
                  _dx = 0;
                }
              : null,
          onHorizontalDragUpdate: d.adjustable
              ? (e) {
                  _dx += e.primaryDelta ?? 0;
                  widget.store.setLevel(d, _start + _dx / box.maxWidth);
                }
              : null,
          child: AnimatedScale(
            scale: d.flash ? .96 : 1,
            duration: const Duration(milliseconds: 300),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(color: on ? p.tileOn : p.glass, borderRadius: BorderRadius.circular(18)),
              clipBehavior: Clip.antiAlias,
              child: Stack(children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: box.maxWidth * fill,
                  child: ColoredBox(color: (d.kind == DeviceKind.cover ? Palette.acc : acc).withValues(alpha: .35)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(children: [
                    TileIcon(device: d, onTap: () => widget.store.toggle(d)),
                    const SizedBox(width: 12),
                    Expanded(child: TileText(device: d)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

class TileIcon extends StatelessWidget {
  const TileIcon({super.key, required this.device, required this.onTap});
  final Device device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = device.isOn;
    final icon = device.kind == DeviceKind.lock && !device.on ? Icons.lock_open_rounded : iconFor(device.id, device.name);
    return Semantics(
      button: true,
      label: '${device.name} ein- oder ausschalten',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: on ? accentOf(device) : const Color(0x26FFFFFF), shape: BoxShape.circle),
          child: Icon(icon, size: 22, color: on ? Colors.white : Palette.of(context).text),
        ),
      ),
    );
  }
}

class TileText extends StatelessWidget {
  const TileText({super.key, required this.device});
  final Device device;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final on = device.isOn;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(device.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, height: 1.2, color: on ? p.ink : p.text)),
      const SizedBox(height: 2),
      Text(statusOf(device),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 13,
              color: on ? p.inkMuted : p.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

/// Große Klima-Kachel (2x2) mit Temperatur-Regler direkt auf dem Balken.
class ClimateTile extends StatelessWidget {
  const ClimateTile({super.key, required this.device, required this.store, required this.onOpen});
  final Device device;
  final HomeStore store;
  final ValueChanged<Device> onOpen;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = device;
    final on = d.on;
    final acc = accentOf(d);
    return Semantics(
      button: true,
      label: '${d.name}, ${statusOf(d)}, Details öffnen',
      child: GestureDetector(
        onTap: () => onOpen(d),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(color: on ? p.tileOn : p.glass, borderRadius: BorderRadius.circular(18)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              TileIcon(device: d, onTap: () => store.toggle(d)),
              const SizedBox(width: 12),
              Expanded(child: TileText(device: d)),
            ]),
            const Spacer(),
            Text.rich(
              TextSpan(children: [
                TextSpan(text: temp(d.target)),
                if (d.current != null)
                  TextSpan(
                      text: '  Innen ${temp(d.current!)}',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, color: on ? p.inkMuted : p.textMuted)),
              ]),
              maxLines: 1,
              style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w500,
                  height: 1,
                  color: on ? p.ink : p.text,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const SizedBox(height: 14),
            _TempTrack(device: d, store: store, color: on ? acc : const Color(0x40FFFFFF)),
          ]),
        ),
      ),
    );
  }
}

class _TempTrack extends StatelessWidget {
  const _TempTrack({required this.device, required this.store, required this.color});
  final Device device;
  final HomeStore store;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final d = device;
    final lim = TextStyle(fontSize: 11, color: d.on ? p.inkMuted : p.textMuted);
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      void at(Offset o) => store.setLevel(d, (o.dx - 12) / (w - 24));
      final t = d.level.clamp(0.0, 1.0);
      return Semantics(
        slider: true,
        label: 'Zieltemperatur',
        value: temp(d.target),
        child: GestureDetector(
          onPanDown: (e) => at(e.localPosition),
          onPanUpdate: (e) => at(e.localPosition),
          child: Container(
            height: 30,
            decoration: BoxDecoration(
                color: d.on ? const Color(0x0F000000) : const Color(0x26FFFFFF), borderRadius: BorderRadius.circular(15)),
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 12 + (w - 24) * t + 12,
                child: DecoratedBox(
                    decoration: BoxDecoration(color: color.withValues(alpha: .9), borderRadius: BorderRadius.circular(15))),
              ),
              Positioned(left: 10, top: 0, bottom: 0, child: Center(child: Text('${d.minTemp.round()}°', style: lim))),
              Positioned(right: 10, top: 0, bottom: 0, child: Center(child: Text('${d.maxTemp.round()}°', style: lim))),
              Positioned(
                left: 12 + (w - 24) * t - 12,
                top: 3,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Color(0x44000000), blurRadius: 4, offset: Offset(0, 1))],
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}
