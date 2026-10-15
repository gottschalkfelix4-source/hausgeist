import 'package:flutter/material.dart';

/// Farben aus dem Prototyp "Home Original". Nachts gedämpft, damit nichts blendet.
class Palette {
  const Palette._({
    required this.night,
    required this.glass,
    required this.tileOn,
    required this.ink,
    required this.inkMuted,
    required this.text,
    required this.textMuted,
    required this.sheet,
  });

  final bool night;
  final Color glass; // Kachel aus
  final Color tileOn; // Kachel an
  final Color ink; // Text auf Kachel an
  final Color inkMuted;
  final Color text; // Text auf Hintergrund
  final Color textMuted;
  final Color sheet; // Detail-Fenster

  static const acc = Color(0xFFFFB340);
  static const ok = Color(0xFF5FD17A);

  static const day = Palette._(
    night: false,
    glass: Color(0x2EFFFFFF),
    tileOn: Color(0xEBFFFFFF),
    ink: Color(0xFF1D1D1F),
    inkMuted: Color(0xFF6E6E73),
    text: Colors.white,
    textMuted: Color(0xA6FFFFFF),
    sheet: Color(0xD926262E),
  );

  static const dark = Palette._(
    night: true,
    glass: Color(0x14FFFFFF),
    tileOn: Color(0xFF34343C),
    ink: Color(0xE6FFFFFF),
    inkMuted: Color(0x8CFFFFFF),
    text: Color(0xD9FFFFFF),
    textMuted: Color(0x80FFFFFF),
    sheet: Color(0xF0141418),
  );

  static Palette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PaletteScope>()?.palette ?? day;
}

class PaletteScope extends InheritedWidget {
  const PaletteScope({super.key, required this.palette, required super.child});
  final Palette palette;
  @override
  bool updateShouldNotify(PaletteScope old) => old.palette != palette;
}

/// Hintergrund: warmes Licht oben links, kühles Blau unten rechts.
class Wallpaper extends StatelessWidget {
  const Wallpaper({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final night = Palette.of(context).night;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-0.35, -1),
          end: Alignment(0.35, 1),
          colors: [Color(0xFF6B5A7A), Color(0xFF2A3550)],
        ),
      ),
      child: Stack(children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.2,
                colors: [Color(0xFFC98B5E), Color(0x00C98B5E)],
                stops: [0, .55],
              ),
            ),
          ),
        ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.bottomRight,
                radius: 1.0,
                colors: [Color(0xFF2C5B7A), Color(0x002C5B7A)],
                stops: [0, .6],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: AnimatedContainer(
            duration: const Duration(seconds: 2),
            color: night ? const Color(0xC7000000) : Colors.transparent,
          ),
        ),
        Positioned.fill(child: child),
      ]),
    );
  }
}

/// Runde Glasfläche (ohne Blur, das spart auf günstigen Tablets viel Leistung).
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 18, this.padding, this.color});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(color: color ?? Palette.of(context).glass, borderRadius: BorderRadius.circular(radius)),
        child: child,
      );
}

IconData iconFor(String id, String name) {
  final n = name.toLowerCase();
  switch (id.split('.').first) {
    case 'light':
      return n.contains('led') || n.contains('streifen') ? Icons.linear_scale_rounded : Icons.lightbulb_outline_rounded;
    case 'climate':
      return Icons.ac_unit_rounded;
    case 'cover':
      return Icons.blinds_outlined;
    case 'media_player':
      return Icons.speaker_outlined;
    case 'scene':
      return Icons.auto_awesome_outlined;
    case 'lock':
      return Icons.lock_outline_rounded;
    case 'fan':
      return Icons.air_rounded;
    default:
      return Icons.power_settings_new_rounded;
  }
}
