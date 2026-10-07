import '../models/channel.dart';
import '../utils/ids.dart';
import 'net.dart';

class M3uParseResult {
  final List<Channel> channels;
  final String? epgUrl;
  const M3uParseResult(this.channels, this.epgUrl);
}

/// Bilerek hoşgörülü yazıldı:
/// - #EXTM3U başlığı olmayan listeleri kabul eder
/// - Sadece URL'lerden oluşan listeleri kabul eder
/// - #EXTVLCOPT ve Kodi tarzı `url|User-Agent=...` başlıklarını okur
/// - Göreli adresleri listenin adresine göre çözer
/// - HTML veya JSON döndüren adresler için anlaşılır hata verir
class M3uParser {
  static final _attr = RegExp(r'([A-Za-z0-9_\-]+)="([^"]*)"');

  static M3uParseResult parse(
    String raw, {
    required String playlistId,
    Uri? baseUri,
  }) {
    var text = raw;
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    final head = text.trimLeft();
    final probe = head.substring(0, head.length < 200 ? head.length : 200).toLowerCase();
    if (probe.startsWith('<!doctype') || probe.startsWith('<html') || probe.startsWith('<?xml')) {
      throw const AppException(
        'Bağlantı bir çalma listesi yerine web sayfası döndürdü. Adresin tam ve doğru olduğundan emin olun.',
      );
    }
    if (head.startsWith('{') || head.startsWith('[')) {
      throw const AppException(
        'Bağlantı JSON döndürdü. Bu bir Xtream hesabıysa "Xtream" sekmesinden ekleyin.',
      );
    }

    String? epg;
    final out = <Channel>[];
    final seen = <String>{};

    var attrs = <String, String>{};
    String? title;
    String? extGroup;
    var headers = <String, String>{};

    void reset() {
      attrs = {};
      title = null;
      extGroup = null;
      headers = {};
    }

    for (var line in text.split(RegExp(r'\r\n|\r|\n'))) {
      line = line.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTM3U')) {
        for (final m in _attr.allMatches(line)) {
          final k = m.group(1)!.toLowerCase();
          if (k == 'url-tvg' || k == 'x-tvg-url' || k == 'tvg-url') {
            epg ??= nonEmpty(m.group(2)!.split(',').first);
          }
        }
        continue;
      }

      if (line.startsWith('#EXTINF')) {
        reset();
        final colon = line.indexOf(':');
        final body = colon >= 0 ? line.substring(colon + 1) : '';
        for (final m in _attr.allMatches(body)) {
          attrs[m.group(1)!.toLowerCase()] = m.group(2)!;
        }
        title = _titleAfterComma(body);
        continue;
      }

      if (line.startsWith('#EXTGRP:')) {
        extGroup = nonEmpty(line.substring(8));
        continue;
      }

      if (line.startsWith('#EXTVLCOPT:')) {
        final opt = line.substring(11);
        final eq = opt.indexOf('=');
        if (eq > 0) {
          final k = opt.substring(0, eq).trim().toLowerCase();
          final v = opt.substring(eq + 1).trim();
          if (k == 'http-user-agent') headers['User-Agent'] = v;
          if (k == 'http-referrer' || k == 'http-referer') headers['Referer'] = v;
          if (k == 'http-origin') headers['Origin'] = v;
        }
        continue;
      }

      if (line.startsWith('#')) continue; // #KODIPROP vb. desteklenmeyen etiketler

      // URL satırı
      var url = line;
      final pipe = url.indexOf('|');
      if (pipe > 0) {
        _parsePipeHeaders(url.substring(pipe + 1), headers);
        url = url.substring(0, pipe);
      }
      if (!url.contains('://') && baseUri != null) {
        url = baseUri.resolve(url).toString();
      }
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        reset();
        continue; // rtmp, udp vb. şimdilik desteklenmiyor
      }

      final name = nonEmpty(title) ?? nonEmpty(attrs['tvg-name']) ?? _nameFromUrl(url);
      final group = nonEmpty(attrs['group-title']) ?? extGroup ?? 'Diğer';
      final id = stableId('$playlistId|$url|$name');

      if (seen.add(id)) {
        out.add(Channel(
          id: id,
          playlistId: playlistId,
          name: name,
          url: url,
          group: group,
          logo: nonEmpty(attrs['tvg-logo']),
          tvgId: nonEmpty(attrs['tvg-id']),
          headers: Map.of(headers),
        ));
      }
      reset();
    }

    if (out.isEmpty) {
      throw const AppException(
        'Listede oynatılabilir kanal bulunamadı. Aboneliğinizin aktif olduğunu kontrol edin.',
      );
    }
    return M3uParseResult(out, epg);
  }

  /// `-1 tvg-name="A, B" group-title="X",Kanal Adı` → `Kanal Adı`
  /// Tırnak içindeki virgülleri atlar.
  static String? _titleAfterComma(String body) {
    var inQuotes = false;
    for (var i = 0; i < body.length; i++) {
      final c = body[i];
      if (c == '"') inQuotes = !inQuotes;
      if (c == ',' && !inQuotes) return nonEmpty(body.substring(i + 1));
    }
    return null;
  }

  static void _parsePipeHeaders(String raw, Map<String, String> into) {
    for (final part in raw.split('&')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final key = part.substring(0, eq).trim();
      var value = part.substring(eq + 1).trim();
      try {
        value = Uri.decodeComponent(value);
      } catch (_) {}
      final lower = key.toLowerCase();
      if (lower == 'user-agent') into['User-Agent'] = value;
      else if (lower == 'referer' || lower == 'referrer') into['Referer'] = value;
      else if (lower == 'origin') into['Origin'] = value;
      else into[key] = value;
    }
  }

  static String _nameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    final seg = uri?.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    return seg ?? uri?.host ?? url;
  }
}
