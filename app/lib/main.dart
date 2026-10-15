import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/api.dart';
import 'core/config.dart';
import 'core/home_store.dart';
import 'display/display_controller.dart';
import 'display/display_service.dart';
import 'ui/home_screen.dart';
import 'ui/setup_screen.dart';
import 'ui/theme.dart';
import 'voice/voice_orb.dart';
import 'voice/voice_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Kiosk: Statusleiste und Navigation ausblenden.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(WallApp(config: await AppConfig.load()));
}

class WallApp extends StatefulWidget {
  const WallApp({super.key, required this.config});
  final AppConfig config;

  @override
  State<WallApp> createState() => _WallAppState();
}

class _WallAppState extends State<WallApp> {
  final _nav = GlobalKey<NavigatorState>();
  late AppConfig _config = widget.config;
  bool _setup = false;

  final DisplayService _display = DisplayService();
  HomeStore? _store;
  VoiceService? _voice;

  @override
  void initState() {
    super.initState();
    _display.addListener(_onDisplay);
    _display.start();
    if (_config.configured) _startStore();
  }

  void _startStore() {
    _voice?.dispose();
    _store?.dispose();
    final store = HomeStore(
      _config.demo ? null : Api(_config.server, _config.token),
      onWake: _display.wake,
      onPresence: _display.presence,
      onDisplaySettings: _display.updateSettings,
    );
    _store = store;
    _voice = VoiceService(
      store,
      onActive: _display.wake,
      presence: () => (seen: _display.ctrl.recentlySeen, near: _display.ctrl.someoneNear),
    );
    store.start();
    _voice!.start();
  }

  void _onDisplay() {
    // Display aus: offene Detail-Fenster schließen, damit der Nächste den Raum sieht.
    if (_display.state == DisplayState.off) _nav.currentState?.popUntil((r) => r.isFirst);
    setState(() {});
  }

  Future<void> _askSettings() async {
    final ok = await showDialog<bool>(
      context: _nav.currentContext!,
      builder: (ctx) => AlertDialog(
        title: const Text('Einrichtung öffnen?'),
        content: const Text('Server und Token dieses Tablets ändern.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Öffnen')),
        ],
      ),
    );
    if (ok == true) setState(() => _setup = true);
  }

  @override
  void dispose() {
    _display.removeListener(_onDisplay);
    _display.dispose();
    _voice?.dispose();
    _store?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = _display.nightTheme ? Palette.dark : Palette.day;
    final off = _display.state == DisplayState.off;
    final showSetup = _setup || !_config.configured || _store == null;
    return MaterialApp(
      title: 'Hausgeist',
      debugShowCheckedModeBanner: false,
      navigatorKey: _nav,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Palette.acc,
        textTheme: ThemeData(brightness: Brightness.dark).textTheme.apply(bodyColor: palette.text, displayColor: palette.text),
      ),
      // Über allem: Farbschema (Tag/Nacht), der schwarze Vorhang, wenn das Display "aus" ist,
      // und darüber die Sprach-Kugel, sobald jemand das Aktivierungswort sagt.
      builder: (context, child) => PaletteScope(
        palette: palette,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _display.touch(),
          child: Stack(children: [
            child!,
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !off,
                child: AnimatedOpacity(
                  opacity: off ? 1 : 0,
                  duration: Duration(milliseconds: off ? 1500 : 150),
                  // Erste Berührung im Ruhezustand weckt nur und löst nichts aus.
                  child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}, child: const ColoredBox(color: Colors.black)),
                ),
              ),
            ),
            if (_voice != null && !showSetup) Positioned.fill(child: VoiceOverlay(voice: _voice!)),
          ]),
        ),
      ),
      home: showSetup
          ? SetupScreen(
              initial: _config,
              onDone: (cfg) => setState(() {
                _config = cfg;
                _setup = false;
                _startStore();
              }),
            )
          : HomeScreen(store: _store!, voice: _voice!, onSettings: _askSettings),
    );
  }
}
