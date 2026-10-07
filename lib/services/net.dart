import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Kullanıcıya doğrudan gösterilebilecek Türkçe hata.
class AppException implements Exception {
  final String message;
  const AppException(this.message);
  @override
  String toString() => message;
}

class Net {
  /// Birçok IPTV sağlayıcısı bilinmeyen istemcileri engeller;
  /// VLC kimliği en geniş uyumluluğu veriyor.
  static const defaultUserAgent = 'VLC/3.0.20 LibVLC/3.0.20';

  static Future<Uint8List> fetchBytes(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw const AppException('Adres http:// veya https:// ile başlamalı.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = true;
    try {
      final req = await client.getUrl(uri);
      req.followRedirects = true;
      req.maxRedirects = 8;
      req.headers.set(HttpHeaders.userAgentHeader, defaultUserAgent);
      headers?.forEach(req.headers.set);
      final resp = await req.close().timeout(timeout);

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw AppException(
          'Sunucu erişimi reddetti (${resp.statusCode}). '
          'Kullanıcı bilgilerini veya abonelik süresini kontrol edin.',
        );
      }
      if (resp.statusCode == 404) {
        throw const AppException('Adres bulunamadı (404). Bağlantıyı kontrol edin.');
      }
      if (resp.statusCode >= 400) {
        throw AppException('Sunucu hata döndürdü: ${resp.statusCode}.');
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(timeout)) {
        builder.add(chunk);
      }
      var bytes = builder.takeBytes();
      // .gz uzantılı EPG dosyaları ve sıkıştırılmış listeler
      if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        bytes = Uint8List.fromList(gzip.decode(bytes));
      }
      return bytes;
    } on AppException {
      rethrow;
    } on TimeoutException {
      throw const AppException('Sunucu zamanında yanıt vermedi. İnternet bağlantınızı kontrol edin.');
    } on SocketException {
      throw const AppException('Sunucuya ulaşılamadı. Adresi ve internet bağlantınızı kontrol edin.');
    } on HandshakeException {
      throw const AppException('Güvenli bağlantı kurulamadı. Adresi http:// ile deneyin.');
    } on HttpException catch (e) {
      throw AppException('Bağlantı hatası: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> fetchText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final bytes = await fetchBytes(url, headers: headers, timeout: timeout);
    return utf8.decode(bytes, allowMalformed: true);
  }
}
