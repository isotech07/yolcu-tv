import 'package:flutter_test/flutter_test.dart';
import 'package:yolcu_tv/models/channel.dart';
import 'package:yolcu_tv/services/m3u_parser.dart';
import 'package:yolcu_tv/services/net.dart';
import 'package:yolcu_tv/services/xtream_client.dart';

void main() {
  group('M3uParser', () {
    test('standart liste: ad, grup, logo, tvg-id, EPG adresi', () {
      const text = '#EXTM3U url-tvg="http://epg.example/guide.xml"\n'
          '#EXTINF:-1 tvg-id="trt1.tr" tvg-logo="http://l/trt1.png" group-title="Ulusal",TRT 1\n'
          'http://s.example/live/1.m3u8\n';
      final r = M3uParser.parse(text, playlistId: 'p');
      expect(r.epgUrl, 'http://epg.example/guide.xml');
      expect(r.channels, hasLength(1));
      final c = r.channels.single;
      expect(c.name, 'TRT 1');
      expect(c.group, 'Ulusal');
      expect(c.logo, 'http://l/trt1.png');
      expect(c.tvgId, 'trt1.tr');
      expect(c.kind, StreamKind.hls);
    });

    test('başlıksız ve sadece URL içeren liste kabul edilir', () {
      final r = M3uParser.parse('http://a.example/stream.ts\nhttp://b.example/x/kanal', playlistId: 'p');
      expect(r.channels.map((c) => c.name), ['stream.ts', 'kanal']);
      expect(r.channels.first.group, 'Diğer');
    });

    test('ad içinde virgül olan tırnaklı özellikler bozmaz', () {
      const text = '#EXTM3U\n#EXTINF:-1 tvg-name="A, B" group-title="Spor, HD",Spor Kanalı, HD\nhttp://x/1.ts';
      final c = M3uParser.parse(text, playlistId: 'p').channels.single;
      expect(c.name, 'Spor Kanalı, HD');
      expect(c.group, 'Spor, HD');
    });

    test('EXTVLCOPT ve pipe başlıkları okunur', () {
      const text = '#EXTM3U\n'
          '#EXTINF:-1,Bir\n#EXTVLCOPT:http-user-agent=Test/1.0\nhttp://x/1.ts\n'
          '#EXTINF:-1,İki\nhttp://x/2.ts|Referer=http%3A%2F%2Fr.example%2F&User-Agent=UA2\n';
      final list = M3uParser.parse(text, playlistId: 'p').channels;
      expect(list[0].headers['User-Agent'], 'Test/1.0');
      expect(list[1].headers['Referer'], 'http://r.example/');
      expect(list[1].headers['User-Agent'], 'UA2');
      expect(list[1].url, 'http://x/2.ts');
    });

    test('EXTGRP grubu kullanılır, göreli adres çözülür', () {
      const text = '#EXTM3U\n#EXTINF:-1,Yerel\n#EXTGRP:Haber\nlive/5.m3u8';
      final c = M3uParser.parse(text, playlistId: 'p', baseUri: Uri.parse('http://h.example/lists/a.m3u')).channels.single;
      expect(c.group, 'Haber');
      expect(c.url, 'http://h.example/lists/live/5.m3u8');
    });

    test('HTML dönen adres anlaşılır hata verir', () {
      expect(
        () => M3uParser.parse('<!DOCTYPE html><html></html>', playlistId: 'p'),
        throwsA(isA<AppException>()),
      );
    });

    test('kimlikler çalıştırmalar arasında sabittir', () {
      const text = '#EXTINF:-1,A\nhttp://x/1.ts';
      final a = M3uParser.parse(text, playlistId: 'p').channels.single.id;
      final b = M3uParser.parse(text, playlistId: 'p').channels.single.id;
      expect(a, b);
    });
  });

  group('Xtream', () {
    test('get.php bağlantısı Xtream hesabı olarak tanınır', () {
      final x = XtreamCredentials.tryParseFromUrl(
        'http://srv.example:8080/get.php?username=ali&password=123&type=m3u_plus&output=ts',
      );
      expect(x, isNotNull);
      expect(x!.server, 'http://srv.example:8080');
      expect(x.username, 'ali');
      expect(x.password, '123');
    });

    test('sıradan M3U bağlantısı Xtream sayılmaz', () {
      expect(XtreamCredentials.tryParseFromUrl('http://a.example/list.m3u'), isNull);
    });
  });
}
