import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/car_server.dart';
import '../services/epg_service.dart';
import '../state/app_state.dart';
import '../widgets/channel_logo.dart';
import 'player_screen.dart';

class ChannelsTab extends StatefulWidget {
  const ChannelsTab({super.key, required this.onAddPlaylist});
  final VoidCallback onAddPlaylist;

  @override
  State<ChannelsTab> createState() => _ChannelsTabState();
}

class _ChannelsTabState extends State<ChannelsTab> {
  static const _all = '__all';
  static const _fav = '__fav';
  static const _recent = '__recent';

  String _group = _all;
  String _query = '';

  List<Channel> _filter(AppState app) {
    final List<Channel> base = switch (_group) {
      _all => app.channels,
      _fav => app.favoriteChannels,
      _recent => app.recentChannels,
      _ => app.channels.where((c) => c.group == _group).toList(),
    };
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final playlist = app.activePlaylist;

    if (playlist == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('İzlemek için önce bir liste ekleyin.'),
            const SizedBox(height: 12),
            FilledButton(onPressed: widget.onAddPlaylist, child: const Text('Liste ekle')),
          ],
        ),
      );
    }

    // Aktif liste değiştiyse ve seçili grup artık yoksa sıfırla.
    if (![_all, _fav, _recent].contains(_group) && !app.groups.contains(_group)) {
      _group = _all;
    }

    final items = _filter(app);
    final chips = <(String, String)>[
      (_all, 'Tümü'),
      if (app.favorites.isNotEmpty) (_fav, 'Favoriler'),
      if (app.recents.isNotEmpty) (_recent, 'Son izlenenler'),
      for (final g in app.groups) (g, g),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          if (context.watch<EpgService>().loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SearchBar(
              hintText: 'Kanal ara',
              leading: const Icon(Icons.search),
              onChanged: (v) => setState(() => _query = v),
              elevation: const WidgetStatePropertyAll(0),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: chips.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ChoiceChip(
                label: Text(chips[i].$2),
                selected: _group == chips[i].$1,
                onSelected: (_) => setState(() => _group = chips[i].$1),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('Bu aramaya uyan kanal yok.'))
                : ListView.builder(
                    itemCount: items.length,
                    itemExtent: 76,
                    itemBuilder: (_, i) => _ChannelTile(
                      channel: items[i],
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PlayerScreen(playlist: items, index: i),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.channel, required this.onTap});
  final Channel channel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final fav = context.select<AppState, bool>((a) => a.isFavorite(channel.id));
    final car = context.watch<CarServer>();
    final now = context.select<EpgService, String?>((e) => e.nowNext(channel.tvgId).now?.title);
    final onCar = car.nowPlaying?.id == channel.id;

    return ListTile(
      onTap: onTap,
      leading: ChannelLogo(channel: channel),
      title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(now ?? channel.group, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (car.running)
            IconButton(
              tooltip: 'Araç ekranında oynat',
              icon: Icon(onCar ? Icons.directions_car_filled : Icons.directions_car_outlined,
                  color: onCar ? Theme.of(context).colorScheme.primary : null),
              onPressed: () {
                car.playOnCar(channel);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${channel.name} araç ekranında açılıyor'), duration: const Duration(seconds: 2)),
                );
              },
            ),
          IconButton(
            tooltip: fav ? 'Favorilerden çıkar' : 'Favorilere ekle',
            icon: Icon(fav ? Icons.star : Icons.star_border),
            onPressed: () => app.toggleFavorite(channel.id),
          ),
        ],
      ),
    );
  }
}
