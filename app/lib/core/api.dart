import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class VoiceReply {
  VoiceReply({required this.reply, this.transcript, this.audio, this.mime = 'audio/mpeg'});
  final String reply;
  final String? transcript;
  final List<int>? audio;

  /// audio/mpeg bei klassischer Stimme, audio/wav bei Live-Sprachmodellen.
  final String mime;

  factory VoiceReply.fromJson(Map<String, dynamic> j) => VoiceReply(
        reply: j['reply'] as String? ?? '',
        transcript: j['transcript'] as String?,
        audio: j['audio_base64'] is String ? base64Decode(j['audio_base64'] as String) : null,
        mime: j['mime'] as String? ?? 'audio/mpeg',
      );
}

/// Spricht mit dem Smarthome-Backend (FastAPI auf dem Unraid-Server).
class Api {
  Api(String server, this.token) : base = Uri.parse(server.trim().replaceAll(RegExp(r'/+$'), ''));

  final Uri base;
  final String token;
  final _http = http.Client();

  Map<String, String> get _headers => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  Uri _u(String path) => base.replace(path: '${base.path}$path');

  Future<Map<String, dynamic>> _json(Future<http.Response> req) async {
    final r = await req.timeout(const Duration(seconds: 30));
    if (r.statusCode == 401) throw ApiException('Token ungültig');
    if (r.statusCode >= 400) throw ApiException('Fehler ${r.statusCode}: ${r.body}');
    if (r.body.isEmpty || r.body == 'null') return const {};
    return (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
  }

  /// Raum, Geräte und Display-Einstellungen dieses Tablets.
  Future<Map<String, dynamic>> me() => _json(_http.get(_u('/api/me'), headers: _headers));

  Future<void> command(String entityId, String action, [Object? value, Map<String, dynamic>? data]) =>
      _json(_http.post(_u('/api/entities/$entityId/command'),
          headers: _headers, body: jsonEncode({'action': action, 'value': value, 'data': data})));

  Future<VoiceReply> voiceText(String text) async =>
      VoiceReply.fromJson(await _json(_http.post(_u('/api/voice/text'), headers: _headers, body: jsonEncode({'text': text}))));

  /// Sprachbefehl als Audiodatei (z. B. WAV) an Spracherkennung und Assistent.
  Future<VoiceReply> voiceAudio(Uint8List audio, {String filename = 'befehl.wav'}) async {
    final req = http.MultipartRequest('POST', _u('/api/voice/audio'))
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(http.MultipartFile.fromBytes('file', audio, filename: filename));
    return VoiceReply.fromJson(await _json(http.Response.fromStream(await _http.send(req))));
  }

  /// Neueste App-Version laut Server (`version`, `apk_url`), leer wenn unbekannt.
  Future<Map<String, dynamic>> appUpdate() => _json(_http.get(_u('/api/app/update'), headers: _headers));

  IOWebSocketChannel? _ws;

  /// Close-Code der letzten Live-Verbindung: 4000 = Einstellungen geändert, 4401 = Token ungültig.
  int? get closeCode => _ws?.closeCode;

  /// Nachricht über die Live-Verbindung an den Server (z. B. `wake_heard`).
  void send(Map<String, dynamic> msg) => _ws?.sink.add(jsonEncode(msg));

  /// Live-Ereignisse (`state`, `wake`, `wake_result`). Der Stream endet, wenn die Verbindung abbricht.
  /// Der Token geht im Header mit, damit er nicht in Proxy-Logs (URL) landet.
  Stream<Map<String, dynamic>> events() {
    final ws = base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '${base.path}/ws');
    final ch = _ws = IOWebSocketChannel.connect(ws,
        headers: {'Authorization': 'Bearer $token'}, pingInterval: const Duration(seconds: 30));
    return ch.stream.map((m) => (jsonDecode(m as String) as Map).cast<String, dynamic>());
  }

  /// Koppelt ein Tablet mit dem 6-stelligen Code aus der Verwaltung und liefert den Token.
  static Future<String> pair(String server, String code) async {
    final base = Uri.parse(server.trim().replaceAll(RegExp(r'/+$'), ''));
    final r = await http
        .post(base.replace(path: '${base.path}/api/pair'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'code': code}))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 404) throw ApiException('Code unbekannt oder abgelaufen');
    if (r.statusCode == 429) throw ApiException('Zu viele Versuche, bitte kurz warten');
    if (r.statusCode >= 400) throw ApiException('Fehler ${r.statusCode}');
    return (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['token'] as String;
  }
}

/// Vergleicht Versionen wie "0.2.0" und "v0.10.1": true, wenn [latest] neuer ist.
bool isNewerVersion(String latest, String current) {
  List<int> parts(String v) =>
      v.replaceFirst(RegExp('^v'), '').split('+').first.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final a = parts(latest), b = parts(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
