enum PlaylistType { m3u, xtream, localFile }

class Playlist {
  final String id;
  String name;
  final PlaylistType type;

  // M3U
  final String? url;

  // Xtream
  final String? server;
  final String? username;
  final String? password;

  String? epgUrl;
  DateTime? updatedAt;
  DateTime? expiresAt;
  int channelCount;

  Playlist({
    required this.id,
    required this.name,
    required this.type,
    this.url,
    this.server,
    this.username,
    this.password,
    this.epgUrl,
    this.updatedAt,
    this.expiresAt,
    this.channelCount = 0,
  });

  bool get canRefresh => type != PlaylistType.localFile;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'url': url,
        'server': server,
        'username': username,
        'password': password,
        'epgUrl': epgUrl,
        'updatedAt': updatedAt?.toIso8601String(),
        'expiresAt': expiresAt?.toIso8601String(),
        'channelCount': channelCount,
      };

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as String,
        name: j['name'] as String,
        type: PlaylistType.values.firstWhere(
          (t) => t.name == j['type'],
          orElse: () => PlaylistType.m3u,
        ),
        url: j['url'] as String?,
        server: j['server'] as String?,
        username: j['username'] as String?,
        password: j['password'] as String?,
        epgUrl: j['epgUrl'] as String?,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
        expiresAt: DateTime.tryParse(j['expiresAt'] as String? ?? ''),
        channelCount: (j['channelCount'] as num?)?.toInt() ?? 0,
      );
}
