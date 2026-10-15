import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../core/api.dart';
import '../core/home_store.dart';

enum VoicePhase { idle, listening, thinking, speaking }

/// Sprachassistent: Mikro gedrückt halten -> Aufnahme -> Backend (STT, LLM, TTS) -> Antwort abspielen.
class VoiceService extends ChangeNotifier {
  VoiceService(this.store);

  final HomeStore store;
  final _rec = AudioRecorder();
  final _player = AudioPlayer();

  VoicePhase phase = VoicePhase.idle;
  String? bubble; // Text in der Sprechblase
  Timer? _hide;

  Future<void> startListening() async {
    if (phase != VoicePhase.idle) return;
    if (store.demo) {
      _show('Ich höre zu …', phase: VoicePhase.listening, keep: true);
      return;
    }
    if (!await _rec.hasPermission()) {
      _show('Kein Zugriff aufs Mikrofon');
      return;
    }
    final dir = await getTemporaryDirectory();
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1),
        path: '${dir.path}/sprache.m4a');
    _show('Ich höre zu …', phase: VoicePhase.listening, keep: true);
  }

  Future<void> stopListening() async {
    if (phase != VoicePhase.listening) return;
    if (store.demo) return _demoReply();
    final path = await _rec.stop();
    if (path == null) return _show('Nichts verstanden');
    _show('Moment …', phase: VoicePhase.thinking, keep: true);
    await _handle(() => store.api!.voiceAudio(File(path)));
  }

  Future<void> sendText(String text) async {
    if (text.trim().isEmpty) return;
    if (store.demo) return _demoReply();
    _show('Moment …', phase: VoicePhase.thinking, keep: true);
    await _handle(() => store.api!.voiceText(text));
  }

  Future<void> _handle(Future<VoiceReply> Function() call) async {
    try {
      final r = await call();
      _show(r.reply, phase: VoicePhase.speaking, keep: true);
      if (r.audio != null) {
        await _player.play(BytesSource(Uint8List.fromList(r.audio!), mimeType: 'audio/mpeg'));
        await _player.onPlayerComplete.first.timeout(const Duration(seconds: 60), onTimeout: () {});
      }
      _show(r.reply);
    } catch (e) {
      _show('Das hat nicht geklappt: $e');
    }
  }

  void _demoReply() {
    final d = store.devices.where((x) => x.id == 'light.decke').firstOrNull;
    if (d != null) store.setLevel(d, .3);
    _show('Ich habe das Deckenlicht auf 30 Prozent gedimmt.');
  }

  void _show(String text, {VoicePhase phase = VoicePhase.idle, bool keep = false}) {
    bubble = text;
    this.phase = phase;
    _hide?.cancel();
    if (!keep) {
      _hide = Timer(const Duration(seconds: 6), () {
        bubble = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _rec.dispose();
    _player.dispose();
    super.dispose();
  }
}
