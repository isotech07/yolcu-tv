/// Tarayıcı tarafında hangi oynatma motorunun önce deneneceğini belirler.
enum StreamKind { hls, mpegts, file }

class Channel {
  final String id;
  final String playlistId;
  final String name;
  final String url;
  final String? logo;
  final String group;
  final String? tvgId;

  /// Sunucunun istediği özel başlıklar (User-Agent, Referer, Origin).
  final Map<String, String> headers;

  const Channel({
    required this.id,
    required this.playlistId,
    required this.name,
    required this.url,
    required this.group,
    this.logo,
    this.tvgId,
    this.headers = const {},
  });

  StreamKind get kind {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    if (path.endsWith('.m3u8') || path.contains('.m3u8')) return StreamKind.hls;
    const files = ['.mp4', '.mkv', '.webm', '.mov', '.m4v', '.avi'];
    if (files.any(path.endsWith)) return StreamKind.file;
    // .ts veya uzantısız canlı yayınların çoğu MPEG-TS'tir.
    return StreamKind.mpegts;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'p': playlistId,
        'n': name,
        'u': url,
        'g': group,
        if (logo != null) 'l': logo,
        if (tvgId != null) 't': tvgId,
        if (headers.isNotEmpty) 'h': headers,
      };

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        id: j['id'] as String,
        playlistId: j['p'] as String,
        name: j['n'] as String,
        url: j['u'] as String,
        group: (j['g'] as String?) ?? 'Diğer',
        logo: j['l'] as String?,
        tvgId: j['t'] as String?,
        headers: (j['h'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            const {},
      );
}
