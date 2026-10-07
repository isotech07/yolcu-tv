import 'package:flutter/foundation.dart';
import 'package:xml/xml_events.dart';

import 'net.dart';

class Programme {
  final DateTime start;
  final DateTime stop;
  final String title;
  const Programme(this.start, this.stop, this.title);

  bool isOnAir(DateTime t) => !t.isBefore(start) && t.isBefore(stop);

  double progress(DateTime t) {
    final total = stop.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (t.difference(start).inSeconds / total).clamp(0, 1).toDouble();
  }
}

class NowNext {
  final Programme? now;
  final Programme? next;
  const NowNext(this.now, this.next);
}

/// XMLTV dosyaları onlarca MB olabilir. DOM kurmak yerine olay akışıyla
/// okuyup sadece listemizdeki kanalların ve yakın zamanın programlarını tutuyoruz.
class EpgService extends ChangeNotifier {
  Map<String, List<Programme>> _byChannel = {};
  bool loading = false;
  String? error;
  String? _loadedUrl;

  bool get hasData => _byChannel.isNotEmpty;

  Future<void> load(String url, Set<String> tvgIds, {bool force = false}) async {
    if (!force && url == _loadedUrl && hasData) return;
    if (tvgIds.isEmpty) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final text = await Net.fetchText(url, timeout: const Duration(seconds: 120));
      final wanted = tvgIds.map((e) => e.toLowerCase()).toSet();
      _byChannel = await compute(_parseEntry, (text, wanted));
      _loadedUrl = url;
    } catch (e) {
      error = 'Yayın akışı yüklenemedi: $e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void clear() {
    _byChannel = {};
    _loadedUrl = null;
    notifyListeners();
  }

  NowNext nowNext(String? tvgId, [DateTime? at]) {
    if (tvgId == null) return const NowNext(null, null);
    final list = _byChannel[tvgId.toLowerCase()];
    if (list == null || list.isEmpty) return const NowNext(null, null);
    final t = at ?? DateTime.now();
    for (var i = 0; i < list.length; i++) {
      if (list[i].isOnAir(t)) {
        return NowNext(list[i], i + 1 < list.length ? list[i + 1] : null);
      }
      if (list[i].start.isAfter(t)) return NowNext(null, list[i]);
    }
    return const NowNext(null, null);
  }

  static Map<String, List<Programme>> _parseEntry((String, Set<String>) args) =>
      _parse(args.$1, args.$2);

  static Map<String, List<Programme>> _parse(String text, Set<String> wanted) {
    final now = DateTime.now();
    final from = now.subtract(const Duration(hours: 3));
    final to = now.add(const Duration(hours: 30));
    final map = <String, List<Programme>>{};

    String? channel;
    DateTime? start;
    DateTime? stop;
    StringBuffer? title;
    var inTitle = false;
    var titleDone = false;

    for (final ev in parseEvents(text)) {
      if (ev is XmlStartElementEvent) {
        if (ev.name == 'programme') {
          String? ch, st, sp;
          for (final a in ev.attributes) {
            if (a.name == 'channel') ch = a.value;
            if (a.name == 'start') st = a.value;
            if (a.name == 'stop') sp = a.value;
          }
          final key = ch?.toLowerCase();
          if (key != null && wanted.contains(key)) {
            channel = key;
            start = _parseTime(st);
            stop = _parseTime(sp);
            title = StringBuffer();
            titleDone = false;
          } else {
            channel = null;
          }
        } else if (ev.name == 'title' && channel != null && !titleDone) {
          inTitle = !ev.isSelfClosing;
        }
      } else if (inTitle && ev is XmlTextEvent) {
        title?.write(ev.value);
      } else if (inTitle && ev is XmlCDATAEvent) {
        title?.write(ev.value);
      } else if (ev is XmlEndElementEvent) {
        if (ev.name == 'title' && inTitle) {
          inTitle = false;
          titleDone = true; // birden fazla dilde başlık varsa ilki
        } else if (ev.name == 'programme' && channel != null) {
          final s = start, e = stop;
          if (s != null && e != null && e.isAfter(from) && s.isBefore(to)) {
            map.putIfAbsent(channel, () => []).add(
                  Programme(s, e, title.toString().trim()),
                );
          }
          channel = null;
        }
      }
    }
    for (final list in map.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    return map;
  }

  /// "20260928180000 +0300" → yerel saat
  static DateTime? _parseTime(String? v) {
    if (v == null || v.length < 14) return null;
    final y = int.tryParse(v.substring(0, 4));
    final mo = int.tryParse(v.substring(4, 6));
    final d = int.tryParse(v.substring(6, 8));
    final h = int.tryParse(v.substring(8, 10));
    final mi = int.tryParse(v.substring(10, 12));
    final s = int.tryParse(v.substring(12, 14));
    if ([y, mo, d, h, mi, s].contains(null)) return null;
    var dt = DateTime.utc(y!, mo!, d!, h!, mi!, s!);
    final tz = v.substring(14).trim();
    if (tz.length >= 5 && (tz[0] == '+' || tz[0] == '-')) {
      final sign = tz[0] == '-' ? -1 : 1;
      final th = int.tryParse(tz.substring(1, 3)) ?? 0;
      final tm = int.tryParse(tz.substring(3, 5)) ?? 0;
      dt = dt.subtract(Duration(hours: th * sign, minutes: tm * sign));
    }
    return dt.toLocal();
  }
}
