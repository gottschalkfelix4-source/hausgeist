import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Aktivierungswort laut Server (`/api/me` → `wake`).
class WakeConfig {
  const WakeConfig({this.enabled = false, this.words = const [], this.keywords = ''});

  factory WakeConfig.fromJson(Map<String, dynamic> j) => WakeConfig(
        enabled: j['enabled'] == true,
        words: [for (final w in (j['words'] as List? ?? const [])) '$w'],
        keywords: j['keywords'] as String? ?? '',
      );

  static const off = WakeConfig();

  final bool enabled;
  final List<String> words;

  /// Fertige Zeilen für den Erkenner („▁COMP U TER #0.2 @Computer“), vom Server zerlegt.
  final String keywords;

  bool get active => enabled && keywords.trim().isNotEmpty;

  @override
  bool operator ==(Object other) => other is WakeConfig && other.enabled == enabled && other.keywords == keywords;

  @override
  int get hashCode => Object.hash(enabled, keywords);
}

/// Offline-Modell für Schlüsselwörter (sherpa-onnx, englisch, 3,3 Mio. Parameter, Apache-2.0).
/// Liegt in den Assets und wird beim ersten Start ausgepackt, weil der Erkenner Dateipfade braucht.
class KwsModel {
  static const version = 'gigaspeech-3.3M-2024-01-01';
  static const files = ['encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'];

  static Future<String> install() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/kws/$version');
    final done = File('${dir.path}/.ok');
    if (await done.exists()) return dir.path;
    await dir.create(recursive: true);
    for (final f in files) {
      final data = await rootBundle.load('assets/kws/$f');
      await File('${dir.path}/$f').writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    }
    await done.writeAsString(version);
    return dir.path;
  }
}

/// Hört im Hintergrund-Isolate auf die Schlüsselwörter, damit die Oberfläche flüssig bleibt.
/// [feed] bekommt 16-kHz-Samples, [detections] liefert den Namen des erkannten Worts.
class KeywordWorker {
  KeywordWorker._(this._isolate, this._send, this._events);

  final Isolate _isolate;
  final SendPort _send;
  final StreamController<String> _events;

  Stream<String> get detections => _events.stream;

  static Future<KeywordWorker> start(String modelDir, String keywords) async {
    final port = ReceivePort();
    final iso = await Isolate.spawn(_run, [port.sendPort, modelDir, keywords], errorsAreFatal: false);
    final events = StreamController<String>.broadcast();
    final ready = Completer<SendPort>();
    port.listen((m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m is String && m.startsWith('error:')) {
        if (!ready.isCompleted) ready.completeError(Exception(m.substring(6)));
      } else if (m is String) {
        events.add(m.replaceAll('_', ' '));
      }
    });
    try {
      final send = await ready.future.timeout(const Duration(seconds: 20));
      return KeywordWorker._(iso, send, events);
    } catch (_) {
      port.close();
      iso.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  void feed(Float32List samples) => _send.send(samples);

  /// Vergisst bisher Gehörtes (z. B. nach einer Antwort, damit sie nicht selbst auslöst).
  void reset() => _send.send('reset');

  void stop() {
    _send.send('stop');
    _events.close();
    Future<void>.delayed(const Duration(seconds: 1), () => _isolate.kill());
  }
}

void _run(List<Object> args) {
  final out = args[0] as SendPort;
  final dir = args[1] as String;
  final keywords = args[2] as String;
  try {
    sherpa.initBindings();
    final spotter = sherpa.KeywordSpotter(sherpa.KeywordSpotterConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$dir/encoder.int8.onnx', decoder: '$dir/decoder.int8.onnx', joiner: '$dir/joiner.int8.onnx'),
        tokens: '$dir/tokens.txt',
        numThreads: 1,
        debug: false,
      ),
      keywordsBuf: keywords,
      keywordsBufSize: utf8.encode(keywords).length,
    ));
    var stream = spotter.createStream();
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    inbox.listen((m) {
      if (m is Float32List) {
        stream.acceptWaveform(samples: m, sampleRate: 16000);
        while (spotter.isReady(stream)) {
          spotter.decode(stream);
          final keyword = spotter.getResult(stream).keyword;
          if (keyword.isNotEmpty) {
            out.send(keyword);
            spotter.reset(stream);
          }
        }
      } else if (m == 'reset') {
        stream.free();
        stream = spotter.createStream();
      } else if (m == 'stop') {
        stream.free();
        spotter.free();
        inbox.close();
      }
    });
  } catch (e) {
    out.send('error:$e');
  }
}
