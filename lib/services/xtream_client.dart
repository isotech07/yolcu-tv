import 'dart:convert';

import '../models/channel.dart';
import '../utils/ids.dart';
import 'net.dart';

class XtreamCredentials {
  final String server;
  final String username;
  final String password;
  const XtreamCredentials(this.server, this.username, this.password);

  /// Kullanıcı `get.php?username=..&password=..` tarzı bir M3U linki yapıştırırsa
  /// bunu Xtream hesabı olarak tanırız: daha hızlı, daha güvenilir ve EPG'li.
  static XtreamCredentials? tryParseFromUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) return null;
    final path = uri.path.toLowerCase();
    if (!(path.endsWith('get.php') || path.endsWith('player_api.php'))) return null;
    final u = uri.queryParameters['username'];
    final p = uri.queryParameters['password'];
    if (u == null || p == null || u.isEmpty || p.isEmpty) return null;
    return XtreamCredentials(uri.origin, u, p);
  }
}

class XtreamAccount {
  final List<String> allowedFormats;
  final DateTime? expiresAt;
  const XtreamAccount(this.allowedFormats, this.expiresAt);
}

class XtreamClient {
  final XtreamCredentials creds;
  XtreamClient(this.creds);

  static String normalizeServer(String input) {
    var t = input.trim();
    if (!t.contains('://')) t = 'http://$t';
    final uri = Uri.parse(t);
    return uri.origin;
  }

  String get base => normalizeServer(creds.server);
  String get _user => Uri.encodeComponent(creds.username);
  String get _pass => Uri.encodeComponent(creds.password);

  String get epgUrl => '$base/xmltv.php?username=$_user&password=$_pass';

  Uri _api([Map<String, String> extra = const {}]) =>
      Uri.parse('$base/player_api.php').replace(queryParameters: {
        'username': creds.username,
        'password': creds.password,
        ...extra,
      });

  Future<dynamic> _get([Map<String, String> extra = const {}]) async {
    final text = await Net.fetchText(_api(extra).toString(), timeout: const Duration(seconds: 90));
    try {
      return jsonDecode(text);
    } on FormatException {
      throw const AppException('Sunucu geçerli bir Xtream yanıtı vermedi. Sunucu adresini kontrol edin.');
    }
  }

  Future<XtreamAccount> authenticate() async {
    final j = await _get();
    if (j is! Map || j['user_info'] is! Map) {
      throw const AppException('Sunucu Xtream hesabı bilgisi döndürmedi.');
    }
    final info = j['user_info'] as Map;
    if ('${info['auth']}' != '1') {
      throw const AppException('Kullanıcı adı veya şifre hatalı.');
    }
    final status = '${info['status'] ?? ''}'.toLowerCase();
    if (status.isNotEmpty && status != 'active') {
      throw AppException('Hesap aktif değil (durum: ${info['status']}).');
    }
    final formats = (info['allowed_output_formats'] as List?)
            ?.map((e) => e.toString().toLowerCase())
            .toList() ??
        const ['ts'];
    final exp = int.tryParse('${info['exp_date'] ?? ''}');
    return XtreamAccount(
      formats,
      exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp * 1000),
    );
  }

  Future<List<Channel>> liveChannels(String playlistId, XtreamAccount account) async {
    final categories = await _get({'action': 'get_live_categories'});
    final names = <String, String>{};
    if (categories is List) {
      for (final c in categories) {
        if (c is Map) names['${c['category_id']}'] = '${c['category_name'] ?? 'Diğer'}';
      }
    }

    final streams = await _get({'action': 'get_live_streams'});
    if (streams is! List) {
      throw const AppException('Kanal listesi alınamadı.');
    }

    // Tarayıcıda (Tesla) HLS daha güvenilir; sunucu izin veriyorsa onu seç.
    final ext = account.allowedFormats.contains('m3u8') ? 'm3u8' : 'ts';

    final out = <Channel>[];
    for (final s in streams) {
      if (s is! Map || s['stream_id'] == null) continue;
      final streamId = '${s['stream_id']}';
      out.add(Channel(
        id: stableId('$playlistId|live|$streamId'),
        playlistId: playlistId,
        name: nonEmpty(s['name']) ?? 'Kanal $streamId',
        url: '$base/live/$_user/$_pass/$streamId.$ext',
        group: names['${s['category_id']}'] ?? 'Diğer',
        logo: nonEmpty(s['stream_icon']),
        tvgId: nonEmpty(s['epg_channel_id']),
      ));
    }
    if (out.isEmpty) {
      throw const AppException('Hesapta canlı kanal bulunamadı.');
    }
    return out;
  }
}
