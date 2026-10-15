import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'voice_service.dart';

/// Vollbild über allem, solange der Sprachassistent aktiv ist: unscharfer Hintergrund, in der Mitte
/// eine leuchtende Kugel, die beim Zuhören auf die Stimme reagiert, beim Nachdenken kreist und beim
/// Antworten pulsiert. Darunter das Verstandene und die Antwort.
class VoiceOverlay extends StatelessWidget {
  const VoiceOverlay({super.key, required this.voice});
  final VoiceService voice;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final on = voice.visible;
        return IgnorePointer(
          ignoring: !on,
          child: AnimatedOpacity(
            opacity: on ? 1 : 0,
            duration: Duration(milliseconds: on ? 220 : 450),
            curve: Curves.easeOut,
            child: _Panel(voice: voice),
          ),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.voice});
  final VoiceService voice;

  String? get _status => switch (voice.phase) {
        VoicePhase.listening => 'Ich höre zu …',
        VoicePhase.thinking => 'Einen Moment …',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final orb = math.min(300.0, math.min(size.width, size.height) * 0.42);
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: voice.close,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                radius: 1.1,
                colors: [Color(0xB0101018), Color(0xE0050508)],
              ),
            ),
            child: SafeArea(
              child: Stack(children: [
                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Semantics(
                        button: voice.phase == VoicePhase.listening,
                        label: voice.phase == VoicePhase.listening ? 'Fertig gesprochen' : null,
                        child: GestureDetector(
                          // Antippen der Kugel beim Zuhören: sofort abschicken.
                          onTap: voice.phase == VoicePhase.listening ? voice.activate : null,
                          child: VoiceOrb(voice: voice, size: orb),
                        ),
                      ),
                      const SizedBox(height: 28),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 680),
                        child: _Texts(voice: voice, status: _status),
                      ),
                    ]),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: IconButton(
                    tooltip: 'Schließen',
                    onPressed: voice.close,
                    iconSize: 30,
                    color: Colors.white70,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Texts extends StatelessWidget {
  const _Texts({required this.voice, required this.status});
  final VoiceService voice;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final lines = <Widget>[
      if (status != null && voice.transcript == null)
        Text(status!, style: const TextStyle(fontSize: 22, color: Colors.white60, fontWeight: FontWeight.w300)),
      if (voice.transcript != null)
        Text('„${voice.transcript}“',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, color: Colors.white, fontWeight: FontWeight.w500, height: 1.25)),
      if (voice.reply != null) ...[
        const SizedBox(height: 14),
        Text(voice.reply!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 21, color: Color(0xFFE8E2D6), fontWeight: FontWeight.w300, height: 1.35)),
      ],
      if (voice.hint != null) ...[
        const SizedBox(height: 12),
        Text(voice.hint!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, color: Color(0xFFFFB340))),
      ],
    ];
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      child: Column(mainAxisSize: MainAxisSize.min, children: lines),
    );
  }
}

/// Die Kugel selbst. Läuft nur, solange sie sichtbar ist.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({super.key, required this.voice, this.size = 280});
  final VoiceService voice;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _state = OrbState();
  Duration _last = Duration.zero;
  FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    widget.voice.addListener(_sync);
    _sync();
    OrbShader.load().then((p) {
      if (mounted && p != null) setState(() => _shader = p.fragmentShader());
    });
  }

  @override
  void didUpdateWidget(VoiceOrb old) {
    super.didUpdateWidget(old);
    if (old.voice != widget.voice) {
      old.voice.removeListener(_sync);
      widget.voice.addListener(_sync);
    }
  }

  void _sync() {
    final run = widget.voice.visible;
    if (run && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration now) {
    final dt = _last == Duration.zero ? 1 / 60 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    setState(() => _state.step(dt.clamp(0, 0.1), widget.voice.phase, widget.voice.level.value));
  }

  @override
  void dispose() {
    widget.voice.removeListener(_sync);
    _ticker.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _shader == null ? OrbPainter(_state) : ShaderOrbPainter(_state, _shader!),
        ),
      );
}

/// Lädt shaders/orb.frag einmal. Klappt das nicht (alte Grafik, Tests), bleibt es bei [OrbPainter].
class OrbShader {
  static Future<FragmentProgram?>? _program;

  static Future<FragmentProgram?> load() => _program ??= FragmentProgram.fromAsset('shaders/orb.frag')
          .then<FragmentProgram?>((p) => p)
          .catchError((Object e) {
        debugPrint('Kugel-Shader nicht verfügbar: $e');
        return null;
      });
}

/// Kugel als Flüssigkeit auf der Grafikkarte, siehe shaders/orb.frag.
class ShaderOrbPainter extends CustomPainter {
  ShaderOrbPainter(this.s, this.shader);
  final OrbState s;
  final FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    shader
      ..setFloat(0, c.dx)
      ..setFloat(1, c.dy)
      ..setFloat(2, size.shortestSide / 2)
      ..setFloat(3, s.t)
      ..setFloat(4, s.level.clamp(0.0, 1.2))
      ..setFloat(5, s.think)
      ..setFloat(6, s.scale)
      ..setFloat(7, s.spin);
    // Etwas größer als das Widget zeichnen, damit das Leuchten Platz hat.
    canvas.drawRect(Rect.fromCenter(center: c, width: size.width * 1.5, height: size.height * 1.5), Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(ShaderOrbPainter old) => true;
}

/// Bewegung der Kugel, getrennt vom Zeichnen (für Tests und die Web-Vorschau).
///
/// Pegel und Größe hängen an gedämpften Federn: Sie folgen der Stimme weich, schwingen ein
/// wenig nach wie Wasser und springen nie.
class OrbState {
  double t = 0; // Sekunden
  double level = 0; // geglätteter Pegel 0..1
  double spin = 0; // Drehung der Farben
  double think = 0; // 0..1, Übergang zum Strudel
  double scale = 0.6; // wächst beim Öffnen auf
  double _levelV = 0, _scaleV = 0, _spinV = 0.35;

  /// Stimme beim Antworten: überlagerte langsame Wellen statt hartem Takt, klingt wie Silben.
  static double speech(double t) {
    final syllables = 0.5 + 0.5 * math.sin(t * 7.3) * math.sin(t * 2.9 + 0.7);
    final phrase = 0.65 + 0.35 * math.sin(t * 1.1 + 1.0);
    return 0.2 + 0.32 * syllables * phrase;
  }

  void step(double dt, VoicePhase phase, double input) {
    t += dt;
    final target = switch (phase) {
      VoicePhase.listening => input,
      VoicePhase.speaking => speech(t),
      _ => 0.0,
    };
    // Rauf straff, runter weicher. Leicht unterdämpft, damit es nachschwappt.
    final up = target > level;
    level = _spring(level, target, dt, up ? 150 : 45, up ? 0.8 : 0.9, (v) => _levelV = v, _levelV);
    final thinking = phase == VoicePhase.thinking ? 1.0 : 0.0;
    think += (thinking - think) * (1 - math.pow(0.9, dt * 60));
    // Auch die Drehung beschleunigt und bremst weich.
    final spinTarget = 0.35 + 0.9 * level + 2.4 * think;
    _spinV += (spinTarget - _spinV) * (1 - math.pow(0.95, dt * 60));
    spin += dt * _spinV;
    final s = phase == VoicePhase.done ? 0.92 : 1.0;
    scale = _spring(scale, s, dt, 90, 0.55, (v) => _scaleV = v, _scaleV);
  }

  /// Gedämpfte Feder (Steifigkeit [k], Dämpfungsgrad [zeta]), in kleinen Schritten gerechnet.
  static double _spring(double x, double target, double dt, double k, double zeta, void Function(double) setV, double v) {
    const h = 1 / 240;
    final c = 2 * zeta * math.sqrt(k);
    for (var left = dt; left > 1e-9; left -= h) {
      final step = math.min(h, left);
      v += ((target - x) * k - v * c) * step;
      x += v * step;
    }
    setV(v);
    return x;
  }
}

class OrbPainter extends CustomPainter {
  OrbPainter(this.s);
  final OrbState s;

  static const _colors = [
    Color(0xFFFFB340), // Bernstein (Hausgeist-Farbe)
    Color(0xFFFF6A5C), // Koralle
    Color(0xFF9B6BFF), // Violett
    Color(0xFF3FD0FF), // Cyan
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = size.shortestSide / 2 * 0.62 * s.scale;
    final r = base * (1 + 0.22 * s.level);

    // Leuchten hinter der Kugel.
    canvas.drawCircle(
      c,
      r * (1.45 + 0.35 * s.level),
      Paint()
        ..shader = RadialGradient(colors: [
          Color.lerp(_colors[0], _colors[2], 0.5 + 0.5 * math.sin(s.t * 0.7))!.withValues(alpha: 0.55 + 0.35 * s.level),
          Color.lerp(_colors[3], _colors[1], 0.5 + 0.5 * math.sin(s.t * 0.5))!.withValues(alpha: 0.18),
          const Color(0x00000000),
        ], stops: const [0.45, 0.75, 1]).createShader(Rect.fromCircle(center: c, radius: r * (1.45 + 0.35 * s.level)))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.3),
    );

    // Umriss: ein Kreis, der beim Sprechen weich wabert.
    final path = Path();
    const n = 96;
    final wobble = 0.012 + 0.065 * s.level + 0.02 * s.think;
    for (var i = 0; i <= n; i++) {
      final a = i / n * 2 * math.pi;
      final d = 1 +
          wobble *
              (0.6 * math.sin(3 * a + s.t * 2.1) +
                  0.4 * math.sin(5 * a - s.t * 3.3 + 1.3) +
                  0.3 * math.sin(2 * a + s.t * 1.2 + 2.0));
      final p = c + Offset(math.cos(a), math.sin(a)) * (r * d);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();

    canvas.save();
    canvas.clipPath(path);
    canvas.drawCircle(
      c,
      r * 1.3,
      Paint()
        ..shader = const RadialGradient(colors: [Color(0xFF2E2140), Color(0xFF141022)])
            .createShader(Rect.fromCircle(center: c, radius: r * 1.3)),
    );

    // Farbflecken, die sich überlagern und umeinander kreisen.
    for (var i = 0; i < _colors.length; i++) {
      final phase = i * math.pi / 2;
      final orbit = r * (0.46 + 0.12 * math.sin(s.t * (0.6 + i * 0.17) + phase) + 0.12 * s.level - 0.1 * s.think);
      final ang = s.spin * (i.isEven ? 1 : -0.8) + phase;
      final p = c + Offset(math.cos(ang), math.sin(ang)) * orbit;
      final br = r * (0.78 + 0.14 * math.sin(s.t * 1.3 + phase) + 0.2 * s.level);
      canvas.drawCircle(
        p,
        br,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(colors: [
            _colors[i].withValues(alpha: 0.72),
            _colors[i].withValues(alpha: 0.28),
            _colors[i].withValues(alpha: 0),
          ], stops: const [0, 0.55, 1])
              .createShader(Rect.fromCircle(center: p, radius: br)),
      );
    }

    // Kreisender Lichtbogen beim Nachdenken.
    if (s.think > 0.02) {
      final rect = Rect.fromCircle(center: c, radius: r * 0.82);
      canvas.drawArc(
        rect,
        s.t * 4,
        math.pi * 1.2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.08
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.plus
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.05)
          ..shader = SweepGradient(
            colors: [const Color(0x00FFFFFF), Colors.white.withValues(alpha: 0.7 * s.think)],
            stops: const [0, 0.6],
            transform: GradientRotation(s.t * 4),
          ).createShader(rect),
      );
    }

    // Glanzlicht oben links, wie eine Glaskugel.
    final hl = c + Offset(-r * 0.32, -r * 0.38);
    canvas.drawCircle(
      hl,
      r * 0.55,
      Paint()
        ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: 0.28), Colors.white.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: hl, radius: r * 0.55)),
    );
    canvas.restore();

    // Feiner Rand.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: 0.18 + 0.2 * s.level),
    );
  }

  @override
  bool shouldRepaint(OrbPainter old) => true;
}
