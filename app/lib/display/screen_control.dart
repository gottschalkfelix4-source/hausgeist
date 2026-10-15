import 'package:flutter/services.dart';

/// Echtes Ausschalten des Bildschirms über Android (siehe Screen.kt). Ohne Freigabe als
/// Geräteadministrator kann eine App die Beleuchtung nur dunkel stellen, nicht abschalten.
/// Außerhalb von Android (Tests, Web-Vorschau) tut sie nichts.
class ScreenControl {
  static const _ch = MethodChannel('hausgeist/screen');

  /// Die Android-Seite antwortet (sonst gibt es den Schalter nicht).
  bool supported = false;

  /// Freigabe als Geräteadministrator ist erteilt.
  bool admin = false;

  /// Kamera hat bei ausgeschaltetem Bildschirm Bewegung gesehen.
  VoidCallback? onMotion;

  void listen() => _ch.setMethodCallHandler((call) async {
        if (call.method == 'motion') onMotion?.call();
      });

  Future<bool> refresh() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('status');
      supported = m != null;
      admin = m?['admin'] == true;
    } catch (_) {
      admin = false;
    }
    return admin;
  }

  Future<void> requestAdmin() => _call('requestAdmin');

  Future<void> removeAdmin() async {
    await _call('removeAdmin');
    admin = false;
  }

  /// Dienst starten, der die App bei ausgeschaltetem Bildschirm am Leben hält.
  Future<void> keepAlive() => _call('keepAlive');

  /// Bildschirm aus. [watch]: Kamera schaut weiter nach Bewegung. false, wenn es nicht ging.
  Future<bool> off({required bool watch}) async {
    try {
      return await _ch.invokeMethod<bool>('off', {'watch': watch}) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> on() => _call('on');

  Future<void> _call(String method) async {
    try {
      await _ch.invokeMethod<void>(method);
    } catch (_) {}
  }
}
