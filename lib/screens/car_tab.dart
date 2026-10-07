import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/car_server.dart';
import '../services/screen_mirror.dart';
import '../state/app_state.dart';
import '../widgets/channel_logo.dart';

class CarTab extends StatelessWidget {
  const CarTab({super.key});

  Future<void> _toggle(BuildContext context, CarServer car, bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      on ? await car.start() : await car.stop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(car.lastError ?? '$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final car = context.watch<CarServer>();
    final app = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final quick = <Channel>[
      ...app.favoriteChannels,
      ...app.recentChannels.where((c) => !app.isFavorite(c.id)),
    ].take(20).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Araç ekranı')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          const _MirrorCard(),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
              title: const Text('Araç ekranı bağlantısı', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(car.running
                  ? '${car.clientCount} ekran bağlı'
                  : 'Tesla tarayıcısından izlemek için açın'),
              value: car.running,
              onChanged: (v) => _toggle(context, car, v),
            ),
          ),
          const SizedBox(height: 12),
          if (car.running) ...[
            _AddressCard(car: car),
            const SizedBox(height: 12),
            if (car.nowPlaying != null) ...[
              _NowPlayingCard(car: car),
              const SizedBox(height: 12),
            ],
          ],
          const _StepsCard(),
          if (car.running && quick.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Hızlı gönder', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final c in quick)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: ChannelLogo(channel: c, size: 44),
                title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Icon(Icons.cast, color: car.nowPlaying?.id == c.id ? scheme.primary : null),
                onTap: () => car.playOnCar(c),
              ),
          ],
        ],
      ),
    );
  }
}

class _MirrorCard extends StatelessWidget {
  const _MirrorCard();

  Future<void> _start(BuildContext context) async {
    final car = context.read<CarServer>();
    final mirror = context.read<ScreenMirror>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      // iPhone'da görüntüyü uzantı sunar; yine de kanal sayfası için ana sunucuyu da açıyoruz.
      if (!car.running) await car.start();
    } catch (_) {
      if (mirror.externalPort == null) {
        messenger.showSnackBar(SnackBar(content: Text(car.lastError ?? 'Bağlantı başlatılamadı.')));
        return;
      }
    }
    await car.refreshAddresses();
    final ok = await mirror.start();
    if (!ok) {
      messenger.showSnackBar(SnackBar(
        content: Text(mirror.lastError ?? 'Ekran yansıtma için izin verilmedi.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mirror = context.watch<ScreenMirror>();
    final car = context.watch<CarServer>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    if (!mirror.supported) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Telefon ekranını yansıt', style: text.titleMedium),
              const SizedBox(height: 8),
              const Text('Ekran yansıtma telefonda çalışır. Bu bilgisayar sürümünde yalnızca kanal yayını denenebilir.'),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Telefon ekranını yansıt', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              mirror.running
                  ? 'Ekranınız araca yansıtılıyor. Diğer uygulamalara geçebilirsiniz.'
                  : 'Telefonda açtığınız her uygulama araç ekranında görünür.',
            ),
            const SizedBox(height: 14),
            if (!mirror.running && mirror.qualitySelectable) ...[
              SegmentedButton<MirrorQuality>(
                segments: [
                  for (final q in MirrorQuality.values)
                    ButtonSegment(value: q, label: Text(q.label)),
                ],
                selected: {mirror.quality},
                onSelectionChanged: (s) => mirror.setQuality(s.first),
              ),
              const SizedBox(height: 14),
            ],
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: mirror.running ? scheme.error : null,
                foregroundColor: mirror.running ? scheme.onError : null,
              ),
              onPressed: mirror.starting ? null : (mirror.running ? mirror.stop : () => _start(context)),
              icon: Icon(mirror.running ? Icons.stop_screen_share : Icons.screen_share),
              label: Text(mirror.running ? 'Yansıtmayı durdur' : 'Yansıtmayı başlat'),
            ),
            if (!mirror.running && Platform.isIOS) ...[
              const SizedBox(height: 10),
              Text(
                'Açılan pencerede "YolcuTV Yansıtma"yı seçip "Yayını Başlat"a dokunun.',
                style: text.bodySmall,
              ),
            ],
            if (mirror.running && car.mirrorUrl != null) ...[
              const SizedBox(height: 14),
              Text('Araç tarayıcısında: ${car.mirrorUrl}',
                  style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
              if (mirror.externalPort == null)
                Text('${car.mirrorViewerCount} ekran izliyor', style: text.bodySmall),
            ],
            const SizedBox(height: 12),
            Text(
              'Ses telefondan veya aracın Bluetooth bağlantısından gelir. '
              'Netflix gibi korumalı uygulamalar güvenlik gereği siyah görünür.',
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.car});
  final CarServer car;

  @override
  Widget build(BuildContext context) {
    final url = car.primaryUrl;
    final scheme = Theme.of(context).colorScheme;
    final others = car.addresses.skip(1).map((a) => 'http://$a:${CarServer.port}').toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Araç tarayıcısında bu adresi açın'),
            const SizedBox(height: 10),
            if (url == null)
              const Text('Ağ adresi bulunamadı. Kişisel erişim noktasını açıp yenileyin.')
            else
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Adres kopyalandı')));
                },
                child: Text(
                  url,
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: scheme.primary),
                ),
              ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Açılmazsa şunları deneyin: ${others.join(', ')}',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: car.refreshAddresses,
                icon: const Icon(Icons.refresh),
                label: const Text('Adresi yenile'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({required this.car});
  final CarServer car;

  @override
  Widget build(BuildContext context) {
    final ch = car.nowPlaying!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: ChannelLogo(channel: ch),
              title: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Araç ekranında oynuyor'),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton.filledTonal(
                  iconSize: 32,
                  onPressed: () => car.zap(-1),
                  icon: const Icon(Icons.skip_previous),
                  tooltip: 'Önceki kanal',
                ),
                IconButton.filled(
                  iconSize: 36,
                  onPressed: car.paused ? car.resumeOnCar : car.pauseOnCar,
                  icon: Icon(car.paused ? Icons.play_arrow : Icons.pause),
                  tooltip: car.paused ? 'Oynat' : 'Duraklat',
                ),
                IconButton.filledTonal(
                  iconSize: 32,
                  onPressed: () => car.zap(1),
                  icon: const Icon(Icons.skip_next),
                  tooltip: 'Sonraki kanal',
                ),
                IconButton.filledTonal(
                  iconSize: 32,
                  onPressed: car.stopOnCar,
                  icon: const Icon(Icons.stop),
                  tooltip: 'Durdur',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepsCard extends StatelessWidget {
  const _StepsCard();

  @override
  Widget build(BuildContext context) {
    final hotspot = Platform.isIOS
        ? 'Ayarlar > Kişisel Erişim Noktası\'nı açın.'
        : 'Ayarlar > Bağlantılar > Mobil erişim noktası\'nı açın.';
    final steps = [
      hotspot,
      'Tesla ekranında Wi-Fi ayarlarından telefonunuzun ağına bağlanın.',
      '"Yansıtmayı başlat"a dokunun ve Tesla tarayıcısında gösterilen adresi açın.',
      'Telefonda istediğiniz uygulamayı açın; görüntü araç ekranına gelir.',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Nasıl bağlanır', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(radius: 13, child: Text('${i + 1}', style: const TextStyle(fontSize: 13))),
                    const SizedBox(width: 12),
                    Expanded(child: Text(steps[i])),
                  ],
                ),
              ),
            const Divider(height: 24),
            const Text(
              'Yayın sırasında uygulamayı açık tutun; ekran otomatik kilitlenmez. '
              'Video yalnızca yolcular veya araç park halindeyken izlenmelidir.',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
