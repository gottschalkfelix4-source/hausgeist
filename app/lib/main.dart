import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      onActive: _display.activity,
      presence: () => (seen: _display.ctrl.recentlySeen, near: _display.ctrl.someoneNear),
      screenOff: () => _display.screenOff,
    );
    _display.onDiag = (text) => store.api?.send({'type': 'diag', 'text': text});
    store.start();
    _voice!.start();
    if (!_config.demo) _offerScreenOff();
  }

  /// Einmalig fragen, ob der Bildschirm ganz ausgehen darf (braucht eine Android-Freigabe).
  Future<void> _offerScreenOff() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('screen_off_offered') ?? false) return;
    await _display.refreshScreen();
    if (!_display.screenSupported || _display.screenAdmin || !mounted) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    final ctx = _nav.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await prefs.setBool('screen_off_offered', true);
    if (!ctx.mounted) return;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('Bildschirm ganz ausschalten?'),
        content: const Text(_screenOffText),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nicht jetzt')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Weiter')),
        ],
      ),
    );
    if (ok == true) await _display.screen.requestAdmin();
  }

  static const _screenOffText = 'Wenn lange niemand das Tablet bedient und niemand im Raum ist, geht der Bildschirm '
      'ganz aus. Sobald die Kamera Bewegung sieht oder der Präsenzmelder anschlägt, geht er wieder an.\n\n'
      'Dafür fragt Android einmal nach der Freigabe als Geräteadministrator. Hausgeist nutzt davon nur '
      '„Bildschirm sperren“.';

  void _onDisplay() {
    // Display aus: offene Detail-Fenster schließen, damit der Nächste den Raum sieht.
    if (_display.state == DisplayState.off) _nav.currentState?.popUntil((r) => r.isFirst);
    setState(() {});
  }

  Future<void> _askSettings() async {
    await _display.refreshScreen();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: _nav.currentContext!,
      builder: (ctx) => AlertDialog(
        title: const Text('Tablet-Einstellungen'),
        content: ListenableBuilder(
          listenable: _display,
          builder: (ctx, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_display.screenSupported) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bildschirm ganz ausschalten'),
                subtitle: Text(_display.screenAdmin
                    ? 'Geht aus, wenn lange niemand da ist, und bei Bewegung wieder an. '
                        'Vor dem Deinstallieren hier ausschalten.'
                    : 'Sonst wird er nur ganz dunkel. Braucht einmal die Freigabe als Geräteadministrator.'),
                value: _display.screenAdmin,
                onChanged: (v) => v ? _display.screen.requestAdmin() : _display.disableScreenOff(),
              ),
              if (_display.screenAdmin && _display.screen.secure) ...[
                Text(
                  'Das Tablet hat eine PIN, ein Muster oder ein Passwort als Displaysperre. Dann fragt Android '
                  'nach dem Aufwachen danach. Stell die Displaysperre auf „Keine“ oder „Wischen“.',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
                TextButton(onPressed: _display.screen.lockSettings, child: const Text('Displaysperre ändern')),
              ],
              if (_display.screenAdmin && !_display.screen.secure && _display.lockBlocked) ...[
                Text(
                  'Nach dem Aufwachen lag der Sperrbildschirm über Hausgeist. Bei manchen Herstellern (z. B. Xiaomi) '
                  'muss Hausgeist dafür „Auf Sperrbildschirm anzeigen“ dürfen.',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
                TextButton(onPressed: _display.screen.lockPermission, child: const Text('Berechtigungen öffnen')),
              ],
              if (_display.screen.device.isNotEmpty)
                Text(_display.screen.device, style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
            ],
            const Text('Server und Token dieses Tablets ändern:'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Schließen')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Einrichtung öffnen')),
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
