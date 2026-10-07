import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/playlist.dart';
import '../services/car_server.dart';
import '../state/app_state.dart';
import 'add_playlist_screen.dart';

class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key, required this.onOpenChannels});
  final VoidCallback onOpenChannels;

  Future<void> _add(BuildContext context) async {
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AddPlaylistScreen()),
    );
    if (added == true && context.mounted) {
      context.read<CarServer>().notifyChannelsChanged();
      onOpenChannels();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Listelerim')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: const Text('Liste ekle'),
      ),
      body: app.playlists.isEmpty
          ? _Empty(onAdd: () => _add(context))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: app.playlists.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _PlaylistCard(
                playlist: app.playlists[i],
                active: app.playlists[i].id == app.activePlaylistId,
                onOpen: onOpenChannels,
              ),
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.playlist_add, size: 64),
            const SizedBox(height: 16),
            Text('Henüz liste yok', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
              'M3U bağlantınızı veya Xtream hesabınızı ekleyin. '
              'Uygulama içerik sağlamaz; kendi listenizi kullanırsınız.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Liste ekle')),
          ],
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatefulWidget {
  const _PlaylistCard({required this.playlist, required this.active, required this.onOpen});
  final Playlist playlist;
  final bool active;
  final VoidCallback onOpen;

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  bool _busy = false;

  String _subtitle() {
    final p = widget.playlist;
    final parts = <String>['${p.channelCount} kanal'];
    if (p.type == PlaylistType.xtream) parts.add('Xtream');
    if (p.type == PlaylistType.localFile) parts.add('Dosya');
    if (p.expiresAt != null) {
      final d = p.expiresAt!;
      parts.add('Bitiş ${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}');
    }
    return parts.join(' • ');
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<AppState>().refresh(widget.playlist);
      if (mounted) context.read<CarServer>().notifyChannelsChanged();
      messenger.showSnackBar(const SnackBar(content: Text('Liste güncellendi')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: widget.playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yeniden adlandır'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Kaydet')),
        ],
      ),
    );
    if (name != null && mounted) await context.read<AppState>().rename(widget.playlist, name);
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Liste silinsin mi?'),
        content: Text('"${widget.playlist.name}" ve bu listedeki favoriler kaldırılacak.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().remove(widget.playlist);
      if (mounted) context.read<CarServer>().notifyChannelsChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.playlist;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: widget.active ? scheme.primary : Colors.transparent, width: 2),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(_subtitle()),
        leading: Icon(widget.active ? Icons.radio_button_checked : Icons.radio_button_off,
            color: widget.active ? scheme.primary : null),
        onTap: () async {
          await context.read<AppState>().setActive(p.id);
          if (context.mounted) context.read<CarServer>().notifyChannelsChanged();
          widget.onOpen();
        },
        trailing: _busy
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'refresh') _refresh();
                  if (v == 'rename') _rename();
                  if (v == 'remove') _remove();
                },
                itemBuilder: (_) => [
                  if (p.canRefresh) const PopupMenuItem(value: 'refresh', child: Text('Yenile')),
                  const PopupMenuItem(value: 'rename', child: Text('Yeniden adlandır')),
                  const PopupMenuItem(value: 'remove', child: Text('Sil')),
                ],
              ),
      ),
    );
  }
}
