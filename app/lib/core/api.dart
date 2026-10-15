import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class VoiceReply {
  VoiceReply({required this.reply, this.transcript, this.audio});
  final String reply;
  final String? transcript;
  final List<int>? audio;

  factory VoiceReply.fromJson(Map<String, dynamic> j) => VoiceReply(
        reply: j['reply'] as String? ?? '',
        transcript: j['transcript'] as String?,
        audio: j['audio_base64'] is String ? base64Decode(j['audio_base64'] as String) : null,
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

  Future<VoiceReply> voiceAudio(File file) async {
    final req = http.MultipartRequest('POST', _u('/api/voice/audio'))
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath('file', file.path, filename: 'sprache.m4a'));
    return VoiceReply.fromJson(await _json(http.Response.fromStream(await _http.send(req))));
  }

  /// Live-Ereignisse (`state`, `wake`). Der Stream endet, wenn die Verbindung abbricht.
  Stream<Map<String, dynamic>> events() {
    final ws = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/ws',
      queryParameters: {'token': token},
    );
    final ch = WebSocketChannel.connect(ws);
    return ch.stream.map((m) => (jsonDecode(m as String) as Map).cast<String, dynamic>());
  }
}
