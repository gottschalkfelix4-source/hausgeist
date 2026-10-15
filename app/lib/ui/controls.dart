import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/device.dart';
import 'theme.dart';

const _white15 = Color(0x26FFFFFF);
const _white12 = Color(0x1FFFFFFF);

/// Großer senkrechter Regler wie bei Apple Home (Helligkeit, Position, Lautstärke).
class VSlider extends StatelessWidget {
  const VSlider({super.key, required this.value, required this.onChanged, this.fill, this.label});
  final double value; // 0..1
  final ValueChanged<double> onChanged;
  final Gradient? fill;
  final String? label;

  @override
  Widget build(BuildContext context) {
    const w = 104.0, h = 280.0;
    void at(Offset p) => onChanged((1 - p.dy / h).clamp(0.0, 1.0));
    final pct = '${(value * 100).round()} %';
    return Semantics(
      slider: true,
      label: label,
      value: pct,
      child: GestureDetector(
        onPanDown: (e) => at(e.localPosition),
        onPanUpdate: (e) => at(e.localPosition),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(30),
          child: Container(
            width: w,
            height: h,
            color: _white15,
            child: Stack(children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: h * value,
                child: DecoratedBox(decoration: BoxDecoration(color: fill == null ? Colors.white : null, gradient: fill)),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 14,
                child: Text(pct,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: value < .14 ? Colors.white : const Color(0xFF1D1D1F))),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Farbrad: Winkel = Farbton, Abstand zur Mitte = Sättigung.
class ColorWheel extends StatelessWidget {
  const ColorWheel({super.key, required this.hue, required this.sat, required this.onChanged, this.size = 220});
  final double hue, sat, size;
  final void Function(double hue, double sat) onChanged;

  @override
  Widget build(BuildContext context) {
    final r = size / 2;
    void at(Offset p) {
      final x = p.dx - r, y = p.dy - r;
      onChanged((math.atan2(y, x) * 180 / math.pi + 360) % 360, (math.sqrt(x * x + y * y) / r).clamp(0.0, 1.0));
    }

    final a = hue * math.pi / 180;
    return GestureDetector(
      onPanDown: (e) => at(e.localPosition),
      onPanUpdate: (e) => at(e.localPosition),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned.fill(child: CustomPaint(painter: _WheelPainter())),
          Positioned(
            left: r + math.cos(a) * sat * r - 13,
            top: r + math.sin(a) * sat * r - 13,
            child: _Mark(color: hsvColor(hue, sat)),
          ),
        ]),
      ),
    );
  }
}

class _WheelPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final rect = Offset.zero & s;
    final center = rect.center;
    final r = s.width / 2;
    c.drawCircle(
        center,
        r,
        Paint()
          ..shader = SweepGradient(colors: [for (var h = 0; h <= 360; h += 30) hsvColor(h.toDouble(), 1)]).createShader(rect));
    c.drawCircle(
        center, r, Paint()..shader = const RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]).createShader(rect));
  }

  @override
  bool shouldRepaint(_WheelPainter old) => false;
}

class _Mark extends StatelessWidget {
  const _Mark({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(0, 1))],
        ),
      );
}

/// Farbtemperatur von warm nach kalt.
class KelvinBar extends StatelessWidget {
  const KelvinBar({super.key, required this.kelvin, required this.min, required this.max, required this.onChanged});
  final int kelvin, min, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        void at(Offset p) => onChanged(((min + (p.dx / w).clamp(0.0, 1.0) * (max - min)) / 50).round() * 50);
        final t = ((kelvin - min) / (max - min)).clamp(0.0, 1.0);
        return GestureDetector(
          onPanDown: (e) => at(e.localPosition),
          onPanUpdate: (e) => at(e.localPosition),
          child: SizedBox(
            height: 40,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(colors: [kelvinColor(min), kelvinColor((min + max) ~/ 2), kelvinColor(max)]),
                  ),
                ),
              ),
              Positioned(left: t * w - 13, top: 7, child: _Mark(color: kelvinColor(kelvin))),
            ]),
          ),
        );
      }),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Warm · $min K', style: _small(context)),
        Text('Kalt · $max K', style: _small(context)),
      ]),
    ]);
  }
}

TextStyle _small(BuildContext context) => TextStyle(fontSize: 12, color: Palette.of(context).textMuted);

/// Thermostat-Ring mit 270°-Bogen.
class ThermostatDial extends StatelessWidget {
  const ThermostatDial({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.color,
    required this.onChanged,
    required this.center,
  });
  final double value, min, max;
  final Color color;
  final ValueChanged<double> onChanged;
  final Widget center;

  @override
  Widget build(BuildContext context) {
    const size = 260.0;
    void at(Offset p) {
      final x = p.dx - size / 2, y = p.dy - size / 2;
      var a = ((math.atan2(y, x) * 180 / math.pi) - 135 + 720) % 360;
      if (a > 270) a = a > 315 ? 0 : 270;
      onChanged(min + a / 270 * (max - min));
    }

    return GestureDetector(
      onPanDown: (e) => at(e.localPosition),
      onPanUpdate: (e) => at(e.localPosition),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _DialPainter(((value - min) / (max - min)).clamp(0.0, 1.0), color),
          child: Center(child: center),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas c, Size s) {
    const r = 110.0;
    final center = s.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: r);
    const start = 135 * math.pi / 180, sweep = 270 * math.pi / 180;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeCap = StrokeCap.round;
    c.drawArc(rect, start, sweep, false, p..color = _white15);
    c.drawArc(rect, start, math.max(sweep * t, 0.001), false, p..color = color);
    final a = start + sweep * t;
    c.drawCircle(center + Offset(math.cos(a), math.sin(a)) * r, 13, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_DialPainter old) => old.t != t || old.color != color;
}

/// Segmentierte Auswahl (z. B. Farbe/Weißtöne, Lüfterstufe).
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.options, required this.selected, required this.onSelect});
  final List<(T, String)> options;
  final T? selected;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: _white12, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        for (final (v, l) in options)
          Expanded(
            child: GestureDetector(
              onTap: () => onSelect(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                decoration: BoxDecoration(
                    color: v == selected ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(9)),
                child: Text(l,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: v == selected ? FontWeight.w500 : FontWeight.w400,
                        color: v == selected ? const Color(0xFF1D1D1F) : Palette.of(context).text)),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Auswahl-Chips (Modus, Helligkeits-Voreinstellungen, Rollo).
class ChoiceChips<T> extends StatelessWidget {
  const ChoiceChips({super.key, required this.options, required this.selected, required this.onSelect});
  final List<(T, String, Color?)> options;
  final T? selected;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (v, l, dot) in options)
        PillButton(
          selected: v == selected,
          onTap: () => onSelect(v),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (dot != null) ...[
              Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
              const SizedBox(width: 8),
            ],
            Text(l),
          ]),
        ),
    ]);
  }
}

class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.child, required this.onTap, this.selected = false});
  final Widget child;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? const Color(0xFF1D1D1F) : Palette.of(context).text;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: selected ? Colors.white : _white12, borderRadius: BorderRadius.circular(12)),
        child: DefaultTextStyle.merge(
          style: TextStyle(fontSize: 14, color: fg, fontWeight: selected ? FontWeight.w500 : FontWeight.w400),
          child: IconTheme.merge(data: IconThemeData(color: fg, size: 20), child: child),
        ),
      ),
    );
  }
}

class RoundButton extends StatelessWidget {
  const RoundButton({super.key, required this.onTap, required this.child, this.size = 34, this.tooltip});
  final VoidCallback onTap;
  final Widget child;
  final double size;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: _white15, shape: BoxShape.circle),
            child: IconTheme.merge(data: IconThemeData(color: Palette.of(context).text, size: size * .5), child: child),
          ),
        ),
      );
}

class OnOffSwitch extends StatelessWidget {
  const OnOffSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) =>
      CupertinoSwitch(value: value, onChanged: onChanged, activeTrackColor: Palette.ok);
}

class OptionRow extends StatelessWidget {
  const OptionRow({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: _white12))),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          OnOffSwitch(value: value, onChanged: onChanged),
        ]),
      );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text.toUpperCase(),
            style: TextStyle(fontSize: 12, letterSpacing: .7, color: Palette.of(context).textMuted)),
      );
}
