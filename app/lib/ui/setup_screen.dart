import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/config.dart';
import 'theme.dart';

/// Ersteinrichtung: Server-Adresse und Kopplungscode aus der Verwaltung eintragen
/// (oder unter "Erweitert" direkt den Tablet-Token).
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.initial, required this.onDone});
  final AppConfig initial;
  final ValueChanged<AppConfig> onDone;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final _server = TextEditingController(
      text: widget.initial.server);
  late final _token = TextEditingController(text: widget.initial.token);
  final _code = TextEditingController();
  late bool _advanced = widget.initial.token.isNotEmpty;
  bool _busy = false;
  String? _msg;

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final server = _server.text.trim();
    final code = _code.text.replaceAll(RegExp(r'\D'), '');
    if (server.isEmpty) return setState(() => _msg = 'Bitte die Server-Adresse eintragen.');
    if (!_advanced && code.length != 6) return setState(() => _msg = 'Der Kopplungscode hat 6 Ziffern.');
    setState(() {
      _busy = true;
      _msg = null;
    });
    String? token;
    try {
      token = _advanced ? _token.text.trim() : await Api.pair(server, code);
      final me = await Api(server, token).me();
      final cfg = AppConfig(server: server, token: token);
      await cfg.save();
      if (!mounted) return;
      _msg = 'Verbunden: ${me['tablet']}';
      widget.onDone(cfg);
    } catch (e) {
      setState(() {
        _msg = 'Verbindung fehlgeschlagen: $e';
        // Code ist schon eingelöst: Token behalten, damit ein neuer Versuch ohne neuen Code geht.
        if (token != null && !_advanced) {
          _token.text = token;
          _advanced = true;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _demo() async {
    const cfg = AppConfig(demo: true);
    await cfg.save();
    widget.onDone(cfg);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    InputDecoration deco(String label, String hint) => InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: const Color(0x1FFFFFFF),
          labelStyle: TextStyle(color: p.textMuted),
          hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        );
    return Scaffold(
      body: Wallpaper(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Glass(
                  radius: 28,
                  padding: const EdgeInsets.all(28),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: Image.asset('assets/logo.png', width: 56, height: 56)),
                      const SizedBox(width: 14),
                      const Text('Hausgeist', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 20),
                    const Text('Wandtablet einrichten', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                        'In der Hausgeist-Verwaltung unter „Tablets“ ein Tablet anlegen. '
                        'Dann hier die Server-Adresse und den angezeigten Code eintragen.',
                        style: TextStyle(color: p.textMuted, height: 1.4)),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      style: const TextStyle(color: Colors.white),
                      decoration: deco('Server', 'http://192.168.1.10:8080'),
                    ),
                    const SizedBox(height: 12),
                    if (_advanced)
                      TextField(
                        controller: _token,
                        style: const TextStyle(color: Colors.white),
                        decoration: deco('Tablet-Token', 'aus der Verwaltung'),
                      )
                    else
                      TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                        onSubmitted: (_) => _busy ? null : _connect(),
                        style: const TextStyle(color: Colors.white, fontSize: 22, letterSpacing: 6),
                        decoration: deco('Kopplungscode', '123456'),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => setState(() {
                          _advanced = !_advanced;
                          _msg = null;
                        }),
                        style: TextButton.styleFrom(foregroundColor: p.textMuted),
                        child: Text(_advanced ? 'Mit Kopplungscode verbinden' : 'Erweitert: Token eingeben'),
                      ),
                    ),
                    if (_msg != null) ...[
                      const SizedBox(height: 12),
                      Text(_msg!, style: TextStyle(color: p.textMuted)),
                    ],
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _busy ? null : _connect,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: const Color(0xFF1D1D1F),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(_busy ? 'Verbinde …' : 'Verbinden'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy ? null : _demo,
                      style: TextButton.styleFrom(foregroundColor: Colors.white),
                      child: const Text('Ohne Server ausprobieren (Demo)'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
