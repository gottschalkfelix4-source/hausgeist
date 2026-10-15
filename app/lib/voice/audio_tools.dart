import 'dart:math' as math;
import 'dart:typed_data';

/// Bausteine für den Mikrofon-Strom (16 kHz, mono, PCM16). Reines Dart, ohne Plugins testbar.

const sampleRate = 16000;

/// Wandelt den Byte-Strom des Rekorders in Samples. Ein übriges Byte wird für den nächsten Block gemerkt.
class Pcm16Decoder {
  int? _carry;

  Int16List add(Uint8List bytes) {
    var data = bytes;
    if (_carry != null) {
      data = Uint8List(bytes.length + 1)
        ..[0] = _carry!
        ..setRange(1, bytes.length + 1, bytes);
      _carry = null;
    }
    final even = data.length & ~1;
    if (even != data.length) _carry = data[data.length - 1];
    final out = Int16List(even ~/ 2);
    final view = ByteData.sublistView(data, 0, even);
    for (var i = 0; i < out.length; i++) {
      out[i] = view.getInt16(i * 2, Endian.little);
    }
    return out;
  }
}

Float32List toFloat(Int16List s) {
  final out = Float32List(s.length);
  for (var i = 0; i < s.length; i++) {
    out[i] = s[i] / 32768.0;
  }
  return out;
}

/// Pegel in dBFS (-100 = Stille, 0 = Vollaussteuerung).
double levelDb(Int16List s) {
  if (s.isEmpty) return -100;
  var sum = 0.0;
  for (final v in s) {
    sum += v * v;
  }
  final rms = math.sqrt(sum / s.length) / 32768.0;
  return rms <= 0 ? -100 : math.max(-100, 20 * math.log(rms) / math.ln10);
}

/// dBFS -> 0..1 für die Animation (-60 dB und leiser = 0).
double levelToUnit(double db) => ((db + 60) / 50).clamp(0.0, 1.0);

/// Merkt sich die Pegel der letzten Sekunde in 100-ms-Stücken. Der lauteste Wert davor
/// beschreibt, wie laut das Aktivierungswort hier ankam (lauter = näher dran).
class RecentLevels {
  RecentLevels({this.keep = 12});
  final int keep;
  final _levels = <double>[];
  final _block = <int>[];

  void add(Int16List s) {
    for (final v in s) {
      _block.add(v);
      if (_block.length == sampleRate ~/ 10) {
        _levels.add(levelDb(Int16List.fromList(_block)));
        if (_levels.length > keep) _levels.removeAt(0);
        _block.clear();
      }
    }
  }

  double get peak => _levels.isEmpty ? -100 : _levels.reduce(math.max);
}

enum EndReason { silence, maxLength, nothingSaid }

/// Erkennt das Ende eines Sprachbefehls am Pegel: nach Sprache eine Pause, oder gar nichts gesagt.
/// Die Schwelle passt sich dem Grundrauschen im Raum an.
class Endpointer {
  Endpointer({
    this.silence = const Duration(milliseconds: 900),
    this.noSpeech = const Duration(seconds: 5),
    this.maxLength = const Duration(seconds: 12),
    this.margin = 9,
  });

  final Duration silence, noSpeech, maxLength;
  final double margin; // dB über dem Grundrauschen gilt als Sprache

  double _floor = -60;
  int _samples = 0, _quietSince = 0, _hold = 0;
  bool spoke = false;

  Duration get _elapsed => Duration(microseconds: _samples * 1000000 ~/ sampleRate);

  /// Die nächsten [blocks] Blöcke weder als Sprache noch als Pause werten (z. B. während der
  /// eigene Signalton läuft).
  void holdOff(int blocks) => _hold = blocks;

  /// Neuen Block (am besten 100 ms) prüfen. Liefert den Grund, sobald die Aufnahme endet.
  EndReason? add(Int16List block) {
    _samples += block.length;
    if (_hold > 0) {
      _hold--;
      _quietSince = _samples;
      return _elapsed >= maxLength ? (spoke ? EndReason.maxLength : EndReason.nothingSaid) : null;
    }
    final db = levelDb(block);
    final speech = db > _floor + margin && db > -50;
    if (!speech) _floor = _floor * 0.9 + math.max(db, -80) * 0.1;
    if (speech) {
      spoke = true;
      _quietSince = _samples;
    }
    if (_elapsed >= maxLength) return spoke ? EndReason.maxLength : EndReason.nothingSaid;
    if (!spoke) return _elapsed >= noSpeech ? EndReason.nothingSaid : null;
    final quiet = Duration(microseconds: (_samples - _quietSince) * 1000000 ~/ sampleRate);
    return quiet >= silence ? EndReason.silence : null;
  }
}

/// WAV-Datei (PCM16, mono) für den Upload zur Spracherkennung.
Uint8List wavBytes(Int16List samples, {int rate = sampleRate}) {
  final data = samples.lengthInBytes;
  final b = ByteData(44 + data);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, data, Endian.little);
  final out = b.buffer.asUint8List();
  out.setRange(44, 44 + data, samples.buffer.asUint8List(samples.offsetInBytes, data));
  return out;
}

/// Kurzer, weicher Zweiklang als Zeichen „Ich höre zu“ (aufsteigend) bzw. „fertig“ (absteigend).
Uint8List chime({bool up = true}) {
  const rate = 22050;
  final notes = up ? [659.25, 987.77] : [987.77, 659.25]; // E5, H5
  const each = 0.11, tail = 0.25;
  final total = ((each * notes.length + tail) * rate).round();
  final s = Int16List(total);
  for (var n = 0; n < notes.length; n++) {
    final start = (n * each * rate).round();
    for (var i = start; i < total; i++) {
      final t = (i - start) / rate;
      final env = math.min(1.0, t / 0.008) * math.exp(-t * 7);
      final v = math.sin(2 * math.pi * notes[n] * t) + 0.25 * math.sin(4 * math.pi * notes[n] * t);
      s[i] = (s[i] + v * env * 5500).round().clamp(-32768, 32767);
    }
  }
  return wavBytes(s, rate: rate);
}
