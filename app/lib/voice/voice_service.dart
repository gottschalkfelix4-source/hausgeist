import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/widgets.dart';
import 'package:record/record.dart';

import '../core/api.dart';
import '../core/home_store.dart';
import 'audio_tools.dart';
import 'wake_word.dart';

/// idle: hört nur aufs Aktivierungswort · waiting: Server entscheidet, welches Tablet antwortet
/// (noch nichts zu sehen) · listening → thinking → speaking → done: die Kugel ist offen.
enum VoicePhase { idle, waiting, listening, thinking, speaking, done }

/// Sprachassistent: Aktivierungswort (offline) oder Mikrofon-Knopf → Befehl aufnehmen, bis man
/// aufhört zu sprechen → Server (Spracherkennung, Assistent, Stimme) → Antwort abspielen.
class VoiceService extends ChangeNotifier with WidgetsBindingObserver {
  VoiceService(this.store, {this.onActive, this.presence});

  final HomeStore store;

  /// Wird aufgerufen, sobald die Kugel aufgeht (Display wecken).
  final VoidCallback? onActive;

  /// Kamera/Berührung: Ist gerade jemand hier bzw. direkt davor? Hilft bei der Wahl des Tablets.
  final ({bool seen, bool near}) Function()? presence;

  final _rec = AudioRecorder();
  final _player = AudioPlayer();
  final _fx = AudioPlayer();

  /// Mikrofonpegel 0..1 für die Animation.
  final level = ValueNotifier<double>(0);

  VoicePhase phase = VoicePhase.idle;
  String? transcript, reply, hint;

  bool get visible => phase != VoicePhase.idle && phase != VoicePhase.waiting;
  bool get wakeActive => _kws != null;
  List<String> get wakeWords => _wake.words;

  StreamSubscription<Uint8List>? _mic;
  Future<bool>? _micStarting;
  final _pcm = Pcm16Decoder();
  final _recent = RecentLevels();
  KeywordWorker? _kws;
  WakeConfig _wake = WakeConfig.off;
  String? _modelDir;
  final _command = BytesBuilder(copy: false);
  final _block = <int>[];
  Endpointer? _end;
  Timer? _close, _demoTimer, _watch;
  DateTime _lastAudio = DateTime.now(), _micSince = DateTime.now(), _listenSince = DateTime.now();
  int _session = 0;
  bool _paused = false, _disposed = false;

  void start() {
    // Signalton und Antwort ohne bzw. nur mit kurzem Audio-Fokus abspielen, damit sie das Mikrofon
    // nicht anhalten.
    unawaited(_fx
        .setAudioContext(AudioContext(android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none)))
        .catchError((_) {}));
    unawaited(_player
        .setAudioContext(
            AudioContext(android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.gainTransientMayDuck)))
        .catchError((_) {}));
    WidgetsBinding.instance.addObserver(this);
    store.addListener(_syncWake);
    _syncWake();
  }

  // ---------- Aktivierungswort ----------

  Future<void> _syncWake() async {
    final want = store.demo ? WakeConfig.off : store.wake;
    if (want == _wake) return;
    _wake = want;
    _kws?.stop();
    _kws = null;
    if (!want.active) {
      if (phase == VoicePhase.idle) await _stopMic();
      notifyListeners();
      return;
    }
    try {
      _modelDir ??= await KwsModel.install();
      final worker = await KeywordWorker.start(_modelDir!, want.keywords);
      if (_disposed || _wake != want) return worker.stop();
      _kws = worker;
      worker.detections.listen(_onKeyword);
      await _ensureMic();
    } catch (e) {
      debugPrint('Aktivierungswort nicht verfügbar: $e');
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _onKeyword(String word) async {
    if (phase != VoicePhase.idle || _paused) return;
    final session = ++_session;
    phase = VoicePhase.waiting;
    _command.clear();
    final p = presence?.call();
    final ok = await store.mayAnswer(level: _recent.peak, presence: p?.seen ?? false, near: p?.near ?? false);
    if (session != _session || phase != VoicePhase.waiting) return;
    if (!ok) {
      // Ein anderes Tablet ist näher dran.
      phase = VoicePhase.idle;
      _command.clear();
      _kws?.reset();
      return;
    }
    _beginListening();
  }

  // ---------- Mikrofon ----------

  Future<bool> _ensureMic() => _micStarting ??= _startMic().whenComplete(() => _micStarting = null);

  Future<bool> _startMic() async {
    if (_mic != null) return true;
    if (_paused || !await _rec.hasPermission()) return false;
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      echoCancel: true,
      // Sonst hält der Rekorder an, sobald etwas anderes (auch der eigene Signalton) Audio-Fokus
      // bekommt, und läuft nicht von selbst weiter.
      audioInterruption: AudioInterruptionMode.none,
      androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition),
    ));
    _micSince = DateTime.now();
    _watch ??= Timer.periodic(const Duration(seconds: 1), _checkMic);
    _mic = stream.listen(_onAudio, onError: (Object e) => debugPrint('Mikrofon: $e'));
    return true;
  }

  /// Wächter: Kommt vom Mikrofon nichts mehr (Anruf, andere App, Treiber), wird es neu gestartet.
  /// Eine offene Kugel bleibt so nie hängen.
  void _checkMic(Timer _) {
    if (_paused || _disposed) return;
    final now = DateTime.now();
    if (phase == VoicePhase.listening) {
      final since = now.difference(_listenSince);
      if (since > const Duration(seconds: 15)) {
        unawaited(_endListening(EndReason.maxLength));
        return;
      }
      if (since > const Duration(seconds: 4) && now.difference(_lastAudio) > const Duration(seconds: 3)) {
        _command.clear();
        _finish(hint: 'Das Mikrofon liefert keinen Ton. Bitte noch einmal versuchen.');
      }
    }
    final last = _lastAudio.isAfter(_micSince) ? _lastAudio : _micSince;
    if (_mic != null && _micStarting == null && now.difference(last) > const Duration(seconds: 2)) {
      debugPrint('Mikrofon liefert nichts, starte neu');
      _micSince = now;
      unawaited(_stopMic().then((_) => _ensureMic()).catchError((Object e) {
        debugPrint('Mikrofon-Neustart: $e');
        return false;
      }));
    }
  }

  Future<void> _stopMic() async {
    final mic = _mic;
    _mic = null;
    if (mic == null) return;
    await mic.cancel();
    await _rec.stop();
  }

  void _onAudio(Uint8List bytes) {
    _lastAudio = DateTime.now();
    final s = _pcm.add(bytes);
    if (s.isEmpty) return;
    switch (phase) {
      case VoicePhase.idle:
        _recent.add(s);
        _kws?.feed(toFloat(s));
      case VoicePhase.waiting:
        _command.add(s.buffer.asUint8List(s.offsetInBytes, s.lengthInBytes));
      case VoicePhase.listening:
        _listen(s);
      default:
        break;
    }
  }

  /// Aufnahme des Befehls; in 100-ms-Stücken auf das Ende prüfen.
  void _listen(Int16List s) {
    _command.add(s.buffer.asUint8List(s.offsetInBytes, s.lengthInBytes));
    for (final v in s) {
      _block.add(v);
      if (_block.length < sampleRate ~/ 10) continue;
      final b = Int16List.fromList(_block);
      _block.clear();
      level.value = levelToUnit(levelDb(b));
      final end = _end?.add(b);
      if (end != null) {
        unawaited(_endListening(end));
        return;
      }
    }
  }

  // ---------- Ablauf ----------

  /// Mikrofon-Knopf: zuhören. Während des Zuhörens: sofort abschicken.
  Future<void> activate() async {
    if (phase == VoicePhase.listening) return _endListening(EndReason.silence);
    if (phase != VoicePhase.idle && phase != VoicePhase.done) return;
    _close?.cancel();
    if (store.demo) return _demo();
    ++_session;
    if (!await _ensureMic()) return _finish(hint: 'Kein Zugriff aufs Mikrofon');
    _command.clear();
    _beginListening();
  }

  void _beginListening() {
    onActive?.call();
    _close?.cancel();
    transcript = reply = hint = null;
    phase = VoicePhase.listening;
    _listenSince = DateTime.now();
    _block.clear();
    _end = Endpointer();
    // Was nach dem Aktivierungswort schon gesagt wurde („Computer, mach das Licht an“), zählt mit.
    final early = _command.takeBytes();
    if (early.isNotEmpty) _listen(Int16List.sublistView(early));
    if (phase != VoicePhase.listening) return;
    // Der eigene Signalton soll weder als Sprache noch als Pause zählen.
    _end!.holdOff(5);
    unawaited(_fx.play(BytesSource(chime(), mimeType: 'audio/wav')).catchError((_) {}));
    notifyListeners();
  }

  Future<void> _endListening(EndReason reason) async {
    if (phase != VoicePhase.listening) return;
    final audio = _command.takeBytes();
    _block.clear();
    level.value = 0;
    if (reason == EndReason.nothingSaid || audio.length < sampleRate * 2 * 0.3) {
      return _finish(hint: 'Ich habe nichts gehört.');
    }
    phase = VoicePhase.thinking;
    notifyListeners();
    await _ask(() => store.api!.voiceAudio(wavBytes(Int16List.sublistView(audio))));
  }

  /// Getippter Befehl (langes Drücken auf den Mikrofon-Knopf).
  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) return;
    _close?.cancel();
    final session = ++_session;
    onActive?.call();
    transcript = text.trim();
    reply = hint = null;
    phase = VoicePhase.thinking;
    notifyListeners();
    if (store.demo) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (session == _session) await _demoAnswer(session);
      return;
    }
    await _ask(() => store.api!.voiceText(text));
  }

  Future<void> _ask(Future<VoiceReply> Function() call) async {
    final session = _session;
    try {
      final r = await call();
      if (session != _session) return;
      if (r.transcript != null && r.transcript!.trim().isNotEmpty) transcript = r.transcript;
      reply = r.reply;
      phase = VoicePhase.speaking;
      notifyListeners();
      if (r.audio != null) {
        // Vor dem Abspielen abonnieren, sonst geht das Ende kurzer Antworten verloren.
        // onPlayerComplete ist zur Laufzeit ein Future<AudioEvent>, darum erst auf void abbilden.
        final done = _player.onPlayerComplete.first.then((_) {});
        await _player.play(BytesSource(Uint8List.fromList(r.audio!), mimeType: r.mime));
        await done.timeout(const Duration(seconds: 60), onTimeout: () {});
      }
      if (session == _session) _finish();
    } catch (e) {
      if (session == _session) _finish(hint: 'Das hat nicht geklappt: $e');
    }
  }

  void _finish({String? hint}) {
    this.hint = hint;
    phase = VoicePhase.done;
    level.value = 0;
    _close?.cancel();
    _close = Timer(Duration(milliseconds: reply != null ? 4500 : 2500), close);
    notifyListeners();
  }

  /// Kugel schließen und wieder aufs Aktivierungswort hören.
  void close() {
    _session++;
    _close?.cancel();
    _demoTimer?.cancel();
    unawaited(_player.stop().catchError((_) {}));
    _command.clear();
    _block.clear();
    level.value = 0;
    transcript = reply = hint = null;
    phase = VoicePhase.idle;
    _kws?.reset();
    if (_kws == null) unawaited(_stopMic());
    if (!_disposed) notifyListeners();
  }

  // ---------- Demo (ohne Server und Mikrofon, für Vorführung und Bildschirmfotos) ----------

  Future<void> _demo() async {
    final session = ++_session;
    onActive?.call();
    transcript = reply = hint = null;
    phase = VoicePhase.listening;
    notifyListeners();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      final t = timer.tick * 0.05;
      final talk = t > 0.5 && t < 2.3 ? 1.0 : 0.0;
      level.value = talk * (0.35 + 0.45 * (math.sin(t * 13).abs() * (0.6 + 0.4 * math.sin(t * 3.1)).abs()));
    });
    await Future<void>.delayed(const Duration(milliseconds: 2700));
    _demoTimer?.cancel();
    level.value = 0;
    if (session != _session) return;
    transcript = 'Mach das Licht gemütlich';
    phase = VoicePhase.thinking;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    if (session == _session) await _demoAnswer(session);
  }

  Future<void> _demoAnswer(int session) async {
    final d = store.devices.where((x) => x.id == 'light.decke').firstOrNull;
    if (d != null) store.setLevel(d, .3);
    reply = 'Ich habe das Deckenlicht auf 30 Prozent gedimmt.';
    phase = VoicePhase.speaking;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 2800));
    if (session == _session) _finish();
  }

  // ---------- Lebenszyklus ----------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _paused = true;
      if (visible || phase == VoicePhase.waiting) close();
      unawaited(_stopMic());
    } else if (state == AppLifecycleState.resumed) {
      _paused = false;
      if (_kws != null) unawaited(_ensureMic());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    store.removeListener(_syncWake);
    _close?.cancel();
    _demoTimer?.cancel();
    _watch?.cancel();
    _kws?.stop();
    unawaited(_mic?.cancel());
    _rec.dispose();
    _player.dispose();
    _fx.dispose();
    level.dispose();
    super.dispose();
  }
}
