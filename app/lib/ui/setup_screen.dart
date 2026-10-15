import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/config.dart';
import 'theme.dart';

/// Ersteinrichtung: Server-Adresse und Tablet-Token (aus der Web-Admin-Oberfläche) eintragen.
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
  bool _busy = false;
  String? _msg;

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final me = await Api(_server.text, _token.text.trim()).me();
      final cfg = AppConfig(server: _server.text.trim(), token: _token.text.trim());
      await cfg.save();
      if (!mounted) return;
      _msg = 'Verbunden: ${me['tablet']}';
      widget.onDone(cfg);
    } catch (e) {
      setState(() => _msg = 'Verbindung fehlgeschlagen: $e');
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
                    Text('Adresse des Hausgeist-Servers und den Tablet-Token eintragen.',
                        style: TextStyle(color: p.textMuted, height: 1.4)),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      style: const TextStyle(color: Colors.white),
                      decoration: deco('Server', 'http://192.168.1.10:8080'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _token,
                      style: const TextStyle(color: Colors.white),
                      decoration: deco('Tablet-Token', 'vom Hausgeist-Server'),
                    ),
                    if (_msg != null) ...[
                      const SizedBox(height: 12),
                      Text(_msg!, style: TextStyle(color: p.textMuted)),
                    ],
                    const SizedBox(height: 20),
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
