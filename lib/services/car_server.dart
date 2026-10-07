import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/channel.dart';
import '../state/app_state.dart';
import 'net.dart';
import 'screen_mirror.dart';

/// Telefonda çalışan küçük web sunucusu.
///
/// Mimari (ekran yansıtma DEĞİL, yayın aktarma):
///   Tesla tarayıcısı  ──HTTP──▶  telefon:8080  ──▶  IPTV sunucusu
///   - "/"            araç ekranı için web oynatıcı
///   - "/api/*"       kanal listesi ve durum
///   - "/proxy"       yayını telefon üzerinden geçirir (CORS, özel başlıklar,
///                    göreli HLS adresleri burada çözülür)
///   - "/ws"          telefon ↔ araç arasında anlık kumanda
///
/// Video telefonda çözülmez; telefon sadece baytları aktarır.
/// Bu yüzden ekran yansıtmaya göre çok daha az ısınır ve pil harcar.
class CarServer extends ChangeNotifier {
  CarServer(this.app, this.mirror) {
    mirror.addListener(_onMirrorState);
    _mirrorWasRunning = mirror.running;
  }

  static const port = 8080;
  static const _staticFiles = {'hls.min.js', 'mpegts.js', 'jmuxer.min.js'};

  final AppState app;
  final ScreenMirror mirror;
  final Set<WebSocketChannel> _clients = {};

  /// Ekran yansıtma izleyicileri. Değer: anahtar kare aldı mı (almadan önce kare gönderilmez).
  final Map<WebSocketChannel, bool> _mirrorClients = {};
  StreamSubscription<Uint8List>? _frameSub;
  StreamSubscription<void>? _resetSub;
  bool _mirrorWasRunning = false;
  final HttpClient _upstream = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = true
    ..idleTimeout = const Duration(seconds: 20);

  HttpServer? _server;
  Channel? nowPlaying;
  bool paused = false;
  List<String> addresses = [];
  String? lastError;

  bool get running => _server != null;
  int get clientCount => _clients.length + _mirrorClients.length;
  int get mirrorViewerCount => _mirrorClients.length;
  String? get primaryUrl => addresses.isEmpty ? null : 'http://${addresses.first}:$port';

  /// Araç tarayıcısında açılacak yansıtma adresi (iPhone'da uzantının portu).
  String? get mirrorUrl {
    if (addresses.isEmpty) return null;
    final p = mirror.externalPort;
    return p == null ? 'http://${addresses.first}:$port/ekran' : 'http://${addresses.first}:$p/';
  }

  // ---------- Yaşam döngüsü ----------

  Future<void> start() async {
    if (running) return;
    lastError = null;
    final router = Router()
      ..get('/', _index)
      ..get('/ekran', _mirrorPage)
      ..get('/ws-ekran', webSocketHandler(_onMirrorSocket))
      ..get('/static/<file>', _static)
      ..get('/api/channels', _channelsApi)
      ..get('/api/state', _stateApi)
      ..get('/proxy', _proxy)
      ..get('/ws', webSocketHandler(_onSocket));

    final handler = const Pipeline()
        .addMiddleware(_cors())
        .addHandler(router.call);

    try {
      _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port, shared: true);
    } on SocketException catch (e) {
      lastError = 'Sunucu başlatılamadı: ${e.message}';
      notifyListeners();
      rethrow;
    }
    _server!.autoCompress = false;
    _frameSub = mirror.frames.listen(_onFrame);
    _resetSub = mirror.resets.listen((_) => _onMirrorReset());
    addresses = await _localAddresses();
    await WakelockPlus.enable();
    notifyListeners();
  }

  Future<void> stop() async {
    await _frameSub?.cancel();
    await _resetSub?.cancel();
    _frameSub = null;
    _resetSub = null;
    for (final c in [..._clients, ..._mirrorClients.keys]) {
      await c.sink.close();
    }
    _clients.clear();
    _mirrorClients.clear();
    await _server?.close(force: true);
    _server = null;
    nowPlaying = null;
    await WakelockPlus.disable();
    notifyListeners();
  }

  Future<void> refreshAddresses() async {
    addresses = await _localAddresses();
    notifyListeners();
  }

  // ---------- Telefondan gelen komutlar ----------

  void playOnCar(Channel ch) {
    nowPlaying = ch;
    paused = false;
    app.markRecent(ch.id);
    _broadcast(_playPayload(ch));
    notifyListeners();
  }

  void pauseOnCar() {
    paused = true;
    _broadcast({'type': 'pause'});
    notifyListeners();
  }

  void resumeOnCar() {
    paused = false;
    _broadcast({'type': 'resume'});
    notifyListeners();
  }

  void stopOnCar() {
    nowPlaying = null;
    _broadcast({'type': 'stop'});
    notifyListeners();
  }

  /// Liste değiştiğinde araç ekranı kanalları yeniden çeksin.
  void notifyChannelsChanged() => _broadcast({'type': 'reload'});

  void zap(int delta) {
    final list = app.channels;
    final current = nowPlaying;
    if (list.isEmpty || current == null) return;
    final i = list.indexWhere((c) => c.id == current.id);
    if (i < 0) return;
    playOnCar(list[(i + delta) % list.length]);
  }

  // ---------- HTTP uç noktaları ----------

  Future<Response> _index(Request req) async {
    final html = await rootBundle.loadString('assets/web/index.html');
    return Response.ok(html, headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    });
  }

  Future<Response> _static(Request req, String file) async {
    if (!_staticFiles.contains(file)) return Response.notFound('');
    final data = await rootBundle.load('assets/web/$file');
    return Response.ok(data.buffer.asUint8List(), headers: {
      'content-type': 'application/javascript; charset=utf-8',
      'cache-control': 'public, max-age=86400',
    });
  }

  Response _channelsApi(Request req) {
    final list = app.channels;
    return _json({
      'playlist': app.activePlaylist?.name,
      'groups': app.groups,
      'channels': [
        for (final c in list)
          {
            'id': c.id,
            'name': c.name,
            'group': c.group,
            if (c.logo != null) 'logo': c.logo,
            if (app.isFavorite(c.id)) 'fav': true,
            if (app.epg.nowNext(c.tvgId).now case final p?) 'now': p.title,
          }
      ],
    });
  }

  Response _stateApi(Request req) => _json({
        'nowPlaying': nowPlaying == null ? null : _playPayload(nowPlaying!),
        'paused': paused,
        'mirror': mirror.running,
        if (mirror.externalPort != null) 'mirrorPort': mirror.externalPort,
      });

  Future<Response> _mirrorPage(Request req) async {
    final html = await rootBundle.loadString('assets/web/ekran.html');
    return Response.ok(html, headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    });
  }

  // ---------- Ekran yansıtma ----------

  void _onMirrorSocket(WebSocketChannel ws, String? protocol) {
    _mirrorClients[ws] = false;
    ws.sink.add(jsonEncode({'type': mirror.running ? 'on' : 'off'}));
    // Yeni izleyici hemen görüntü alsın diye anahtar kare iste.
    mirror.requestKeyFrame();
    notifyListeners();
    ws.stream.listen(
      (_) {},
      onDone: () {
        _mirrorClients.remove(ws);
        notifyListeners();
      },
      onError: (_) {
        _mirrorClients.remove(ws);
        notifyListeners();
      },
    );
  }

  void _onFrame(Uint8List frame) {
    if (_mirrorClients.isEmpty || frame.isEmpty) return;
    final key = frame[0] == 1;
    for (final entry in _mirrorClients.entries.toList()) {
      if (!entry.value) {
        if (!key) continue; // çözücü anahtar kareden başlamalı
        _mirrorClients[entry.key] = true;
      }
      try {
        entry.key.sink.add(frame);
      } catch (_) {
        _mirrorClients.remove(entry.key);
      }
    }
  }

  void _onMirrorReset() {
    final msg = jsonEncode({'type': 'reset'});
    for (final ws in _mirrorClients.keys.toList()) {
      _mirrorClients[ws] = false;
      try {
        ws.sink.add(msg);
      } catch (_) {}
    }
  }

  void _onMirrorState() {
    if (mirror.running == _mirrorWasRunning) return;
    _mirrorWasRunning = mirror.running;
    // Kanal sayfası açıksa yansıtma sayfasına geçsin (ve tersi).
    _broadcast({
      'type': 'mirror',
      'on': mirror.running,
      if (mirror.externalPort != null) 'port': mirror.externalPort,
    });
    final msg = jsonEncode({'type': mirror.running ? 'on' : 'off'});
    for (final ws in _mirrorClients.keys.toList()) {
      if (!mirror.running) _mirrorClients[ws] = false;
      try {
        ws.sink.add(msg);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<Response> _proxy(Request req) async {
    final uParam = req.url.queryParameters['u'];
    if (uParam == null) return Response.badRequest(body: 'u eksik');

    final Uri target;
    try {
      target = Uri.parse(_unb64(uParam));
    } catch (_) {
      return Response.badRequest(body: 'geçersiz adres');
    }
    if (target.scheme != 'http' && target.scheme != 'https') {
      return Response.forbidden('desteklenmeyen şema');
    }

    final hParam = req.url.queryParameters['h'];
    final extra = <String, String>{};
    if (hParam != null) {
      try {
        (jsonDecode(_unb64(hParam)) as Map).forEach((k, v) => extra['$k'] = '$v');
      } catch (_) {}
    }

    final HttpClientResponse res;
    try {
      final up = await _upstream.getUrl(target);
      up.followRedirects = true;
      up.maxRedirects = 8;
      up.headers.set(HttpHeaders.userAgentHeader, Net.defaultUserAgent);
      extra.forEach(up.headers.set);
      final range = req.headers['range'];
      if (range != null) up.headers.set(HttpHeaders.rangeHeader, range);
      res = await up.close().timeout(const Duration(seconds: 20));
    } catch (e) {
      return Response(502, body: 'Kaynağa bağlanılamadı: $e');
    }

    // Yönlendirme sonrası gerçek adres: HLS içindeki göreli yollar buna göre çözülür.
    var finalUri = target;
    for (final r in res.redirects) {
      finalUri = finalUri.resolveUri(r.location);
    }

    final contentType = res.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    final isPlaylist = contentType.toLowerCase().contains('mpegurl') ||
        finalUri.path.toLowerCase().endsWith('.m3u8');

    if (isPlaylist && res.statusCode < 400) {
      final bytes = await _collect(res);
      final body = utf8.decode(bytes, allowMalformed: true);
      if (body.trimLeft().startsWith('#EXTM3U')) {
        return Response.ok(_rewriteHls(body, finalUri, hParam), headers: {
          'content-type': 'application/vnd.apple.mpegurl',
          'cache-control': 'no-cache',
        });
      }
      // .m3u8 uzantılı ama aslında TS döndüren sunucular var.
      return Response(res.statusCode, body: bytes, headers: {
        'content-type': contentType.isEmpty ? 'video/mp2t' : contentType,
      });
    }

    final headers = <String, String>{
      'content-type': contentType.isEmpty ? _guessType(finalUri) : contentType,
      'cache-control': 'no-cache',
    };
    final compressed = res.headers.value(HttpHeaders.contentEncodingHeader) != null;
    for (final h in ['content-length', 'content-range', 'accept-ranges']) {
      if (h == 'content-length' && compressed) continue;
      final v = res.headers.value(h);
      if (v != null) headers[h] = v;
    }

    // Canlı yayın sonsuz bir akıştır: tamponlamadan aktar.
    // Araç bağlantıyı kapatınca shelf aboneliği iptal eder, kaynak bağlantı da kapanır.
    return Response(
      res.statusCode,
      body: res,
      headers: headers,
      context: {'shelf.io.buffer_output': false},
    );
  }

  /// HLS listesindeki her segment ve alt liste adresini proxy üzerinden geçirir.
  String _rewriteHls(String body, Uri base, String? hParam) {
    final uriAttr = RegExp(r'URI="([^"]+)"');
    return body.split('\n').map((raw) {
      final line = raw.trimRight();
      final t = line.trim();
      if (t.isEmpty) return line;
      if (t.startsWith('#')) {
        return t.replaceAllMapped(uriAttr, (m) {
          return 'URI="${_proxyPath(base.resolve(m.group(1)!).toString(), hParam)}"';
        });
      }
      return _proxyPath(base.resolve(t).toString(), hParam);
    }).join('\n');
  }

  // ---------- WebSocket ----------

  void _onSocket(WebSocketChannel ws, String? protocol) {
    _clients.add(ws);
    notifyListeners();
    if (nowPlaying != null) {
      ws.sink.add(jsonEncode(_playPayload(nowPlaying!)));
      if (paused) ws.sink.add(jsonEncode({'type': 'pause'}));
    }
    ws.stream.listen(
      (msg) {
        try {
          final j = jsonDecode(msg as String) as Map;
          switch (j['type']) {
            case 'play':
              final ch = app.channelById('${j['id']}');
              if (ch != null) playOnCar(ch);
            case 'next':
              zap(1);
            case 'prev':
              zap(-1);
            case 'favorite':
              app.toggleFavorite('${j['id']}');
            case 'paused':
              paused = j['value'] == true;
              notifyListeners();
          }
        } catch (_) {}
      },
      onDone: () {
        _clients.remove(ws);
        notifyListeners();
      },
      onError: (_) {
        _clients.remove(ws);
        notifyListeners();
      },
    );
  }

  void _broadcast(Map<String, dynamic> msg) {
    final text = jsonEncode(msg);
    for (final c in _clients.toList()) {
      try {
        c.sink.add(text);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  Map<String, dynamic> _playPayload(Channel c) => {
        'type': 'play',
        'channel': {
          'id': c.id,
          'name': c.name,
          'group': c.group,
          if (c.logo != null) 'logo': c.logo,
          if (app.epg.nowNext(c.tvgId).now case final p?) 'now': p.title,
        },
        'src': _proxyPath(
          c.url,
          c.headers.isEmpty ? null : _b64(jsonEncode(c.headers)),
        ),
        'kind': c.kind.name,
      };

  // ---------- Yardımcılar ----------

  static String _proxyPath(String url, String? hParam) =>
      '/proxy?u=${_b64(url)}${hParam == null ? '' : '&h=$hParam'}';

  static String _b64(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');

  static String _unb64(String s) => utf8.decode(base64Url.decode(base64Url.normalize(s)));

  static Response _json(Object body) => Response.ok(
        jsonEncode(body),
        headers: {'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store'},
      );

  static Future<List<int>> _collect(Stream<List<int>> s) async {
    final b = BytesBuilder(copy: false);
    await for (final c in s) {
      b.add(c);
    }
    return b.takeBytes();
  }

  static String _guessType(Uri u) {
    final p = u.path.toLowerCase();
    if (p.endsWith('.mp4') || p.endsWith('.m4v')) return 'video/mp4';
    if (p.endsWith('.webm')) return 'video/webm';
    if (p.endsWith('.mkv')) return 'video/x-matroska';
    if (p.endsWith('.aac')) return 'audio/aac';
    if (p.endsWith('.m4s')) return 'video/iso.segment';
    return 'video/mp2t';
  }

  static Middleware _cors() => (inner) => (req) async {
        const h = {
          'access-control-allow-origin': '*',
          'access-control-allow-headers': 'range, content-type',
          'access-control-expose-headers': 'content-length, content-range',
        };
        if (req.method == 'OPTIONS') return Response.ok('', headers: h);
        final r = await inner(req);
        return r.change(headers: h);
      };

  /// Erişim noktası adresini en üste koyar:
  /// iPhone hotspot'u her zaman 172.20.10.1, Android genelde x.x.x.1 olur.
  static Future<List<String>> _localAddresses() async {
    final list = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final i in ifaces) {
        for (final a in i.addresses) {
          list.add(a.address);
        }
      }
    } catch (_) {}
    int score(String ip) {
      if (ip == '172.20.10.1') return 4;
      if (ip.startsWith('192.168.') && ip.endsWith('.1')) return 3;
      if (ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')) return 2;
      return 1;
    }

    list.sort((a, b) => score(b) - score(a));
    return list;
  }

  @override
  void dispose() {
    mirror.removeListener(_onMirrorState);
    stop();
    _upstream.close(force: true);
    super.dispose();
  }
}
