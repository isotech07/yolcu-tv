import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/channel.dart';
import '../models/playlist.dart';
import '../services/epg_service.dart';
import '../services/m3u_parser.dart';
import '../services/net.dart';
import '../services/xtream_client.dart';
import '../utils/ids.dart';

class AppState extends ChangeNotifier {
  final List<Playlist> playlists = [];
  final Map<String, List<Channel>> _channels = {};
  final Set<String> favorites = {};
  final List<String> recents = [];
  final EpgService epg = EpgService();

  String? activePlaylistId;
  bool passengerWarningAccepted = false;
  bool ready = false;

  late Directory _dir;

  // ---------- Başlatma ve kayıt ----------

  Future<void> init() async {
    _dir = await getApplicationSupportDirectory();
    final file = File('${_dir.path}/state.json');
    if (await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        playlists.addAll(((j['playlists'] as List?) ?? const [])
            .map((e) => Playlist.fromJson(Map<String, dynamic>.from(e as Map))));
        favorites.addAll(((j['favorites'] as List?) ?? const []).cast<String>());
        recents.addAll(((j['recents'] as List?) ?? const []).cast<String>());
        activePlaylistId = j['active'] as String?;
        passengerWarningAccepted = j['warn'] == true;
      } catch (_) {
        // Bozuk kayıt dosyası uygulamayı kilitlemesin.
      }
    }
    for (final p in playlists) {
      await _readChannels(p.id);
    }
    if (activePlaylistId == null || !playlists.any((p) => p.id == activePlaylistId)) {
      activePlaylistId = playlists.isEmpty ? null : playlists.first.id;
    }
    ready = true;
    notifyListeners();
    _loadEpgForActive();
  }

  Future<void> _save() async {
    final file = File('${_dir.path}/state.json');
    await file.writeAsString(jsonEncode({
      'playlists': playlists.map((p) => p.toJson()).toList(),
      'favorites': favorites.toList(),
      'recents': recents,
      'active': activePlaylistId,
      'warn': passengerWarningAccepted,
    }));
  }

  File _channelsFile(String id) => File('${_dir.path}/channels_$id.json');

  Future<void> _readChannels(String id) async {
    final f = _channelsFile(id);
    if (!await f.exists()) return;
    try {
      final text = await f.readAsString();
      _channels[id] = await compute(_decodeChannels, text);
    } catch (_) {
      _channels[id] = const [];
    }
  }

  Future<void> _writeChannels(String id, List<Channel> list) async {
    final text = await compute(_encodeChannels, list);
    await _channelsFile(id).writeAsString(text);
  }

  // ---------- Okuma ----------

  Playlist? get activePlaylist =>
      playlists.where((p) => p.id == activePlaylistId).firstOrNull;

  List<Channel> get channels =>
      activePlaylistId == null ? const [] : (_channels[activePlaylistId] ?? const []);

  List<String> get groups {
    final seen = <String>{};
    return [for (final c in channels) if (seen.add(c.group)) c.group];
  }

  Channel? channelById(String id) {
    for (final list in _channels.values) {
      for (final c in list) {
        if (c.id == id) return c;
      }
    }
    return null;
  }

  List<Channel> get favoriteChannels =>
      [for (final id in favorites) if (channelById(id) case final c?) c];

  List<Channel> get recentChannels =>
      [for (final id in recents) if (channelById(id) case final c?) c];

  // ---------- Liste ekleme ----------

  Future<void> addM3u(String name, String url, {String? epgUrl}) async {
    // get.php linki yapıştırıldıysa Xtream olarak ekle: EPG ve kategoriler daha iyi.
    final x = XtreamCredentials.tryParseFromUrl(url);
    if (x != null) {
      return addXtream(name, x.server, x.username, x.password);
    }
    final p = Playlist(
      id: newId(),
      name: name.trim().isEmpty ? 'Listem' : name.trim(),
      type: PlaylistType.m3u,
      url: url.trim(),
      epgUrl: nonEmpty(epgUrl),
    );
    await _fetchInto(p);
    await _addPlaylist(p);
  }

  Future<void> addXtream(String name, String server, String user, String pass) async {
    final p = Playlist(
      id: newId(),
      name: name.trim().isEmpty ? 'Xtream' : name.trim(),
      type: PlaylistType.xtream,
      server: XtreamClient.normalizeServer(server),
      username: user.trim(),
      password: pass.trim(),
    );
    await _fetchInto(p);
    await _addPlaylist(p);
  }

  Future<void> addLocalFile(String name, String content) async {
    final p = Playlist(id: newId(), name: name, type: PlaylistType.localFile);
    final result = await compute(_parseM3u, (content, p.id, null));
    p.epgUrl = result.epgUrl;
    await _store(p, result.channels);
    await _addPlaylist(p);
  }

  Future<void> _addPlaylist(Playlist p) async {
    playlists.add(p);
    activePlaylistId = p.id;
    await _save();
    notifyListeners();
    _loadEpgForActive(force: true);
  }

  Future<void> _fetchInto(Playlist p) async {
    switch (p.type) {
      case PlaylistType.xtream:
        final client = XtreamClient(XtreamCredentials(p.server!, p.username!, p.password!));
        final account = await client.authenticate();
        final list = await client.liveChannels(p.id, account);
        p.epgUrl ??= client.epgUrl;
        p.expiresAt = account.expiresAt;
        await _store(p, list);
      case PlaylistType.m3u:
        final url = p.url!;
        final text = await Net.fetchText(url, timeout: const Duration(seconds: 90));
        final result = await compute(_parseM3u, (text, p.id, url));
        p.epgUrl ??= result.epgUrl;
        await _store(p, result.channels);
      case PlaylistType.localFile:
        return;
    }
  }

  Future<void> _store(Playlist p, List<Channel> list) async {
    _channels[p.id] = list;
    p.channelCount = list.length;
    p.updatedAt = DateTime.now();
    await _writeChannels(p.id, list);
  }

  // ---------- Liste yönetimi ----------

  Future<void> refresh(Playlist p) async {
    await _fetchInto(p);
    await _save();
    notifyListeners();
    if (p.id == activePlaylistId) _loadEpgForActive(force: true);
  }

  Future<void> rename(Playlist p, String name) async {
    if (name.trim().isEmpty) return;
    p.name = name.trim();
    await _save();
    notifyListeners();
  }

  Future<void> remove(Playlist p) async {
    playlists.remove(p);
    final removed = _channels.remove(p.id) ?? const [];
    final ids = removed.map((c) => c.id).toSet();
    favorites.removeAll(ids);
    recents.removeWhere(ids.contains);
    final f = _channelsFile(p.id);
    if (await f.exists()) await f.delete();
    if (activePlaylistId == p.id) {
      activePlaylistId = playlists.isEmpty ? null : playlists.first.id;
      epg.clear();
      _loadEpgForActive();
    }
    await _save();
    notifyListeners();
  }

  Future<void> setActive(String id) async {
    if (activePlaylistId == id) return;
    activePlaylistId = id;
    epg.clear();
    await _save();
    notifyListeners();
    _loadEpgForActive();
  }

  void _loadEpgForActive({bool force = false}) {
    final p = activePlaylist;
    final url = p?.epgUrl;
    if (url == null) return;
    final ids = {for (final c in channels) if (c.tvgId != null) c.tvgId!};
    epg.load(url, ids, force: force);
  }

  Future<void> reloadEpg() async => _loadEpgForActive(force: true);

  // ---------- Kullanıcı tercihleri ----------

  bool isFavorite(String id) => favorites.contains(id);

  Future<void> toggleFavorite(String id) async {
    if (!favorites.remove(id)) favorites.add(id);
    notifyListeners();
    await _save();
  }

  Future<void> markRecent(String id) async {
    recents
      ..remove(id)
      ..insert(0, id);
    if (recents.length > 30) recents.removeRange(30, recents.length);
    notifyListeners();
    await _save();
  }

  Future<void> acceptPassengerWarning() async {
    passengerWarningAccepted = true;
    await _save();
    notifyListeners();
  }
}

// ---------- Arka plan iş parçacığında çalışan üst düzey fonksiyonlar ----------
// compute() yalnızca üst düzey/statik fonksiyonlarla güvenle çalışır.

List<Channel> _decodeChannels(String text) => (jsonDecode(text) as List)
    .map((e) => Channel.fromJson(Map<String, dynamic>.from(e as Map)))
    .toList();

String _encodeChannels(List<Channel> list) =>
    jsonEncode(list.map((c) => c.toJson()).toList());

M3uParseResult _parseM3u((String, String, String?) args) {
  final (text, playlistId, url) = args;
  return M3uParser.parse(
    text,
    playlistId: playlistId,
    baseUri: url == null ? null : Uri.parse(url),
  );
}
