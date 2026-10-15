import 'package:shared_preferences/shared_preferences.dart';

/// Verbindungsdaten des Tablets, lokal gespeichert.
class AppConfig {
  const AppConfig({this.server = '', this.token = '', this.demo = false});

  final String server; // z. B. http://192.168.1.10:8080
  final String token;
  final bool demo;

  bool get configured => demo || (server.isNotEmpty && token.isNotEmpty);

  static Future<AppConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return AppConfig(
      server: p.getString('server') ?? '',
      token: p.getString('token') ?? '',
      demo: p.getBool('demo') ?? false,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('server', server);
    await p.setString('token', token);
    await p.setBool('demo', demo);
  }
}
