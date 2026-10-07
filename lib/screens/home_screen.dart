import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'car_tab.dart';
import 'channels_tab.dart';
import 'playlists_tab.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWarn());
  }

  Future<void> _maybeWarn() async {
    final app = context.read<AppState>();
    if (app.passengerWarningAccepted || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 40),
        title: const Text('Güvenlik uyarısı'),
        content: const Text(
          'Bu uygulama yolcuların ve park halindeki araçların kullanımı içindir.\n\n'
          'Araç kullanırken asla video izlemeyin veya uygulamayı kullanmayın.\n\n'
          'Uygulama içerik sağlamaz. Eklediğiniz listeleri kullanma hakkına sahip olmaktan siz sorumlusunuz.',
        ),
        actions: [
          FilledButton(
            onPressed: () {
              app.acceptPassengerWarning();
              Navigator.pop(ctx);
            },
            child: const Text('Anladım'),
          ),
        ],
      ),
    );
  }

  void _goTo(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    // Ana özellik ekran yansıtma olduğu için uygulama "Araç ekranı" sekmesiyle açılır.
    final pages = [
      const CarTab(),
      ChannelsTab(onAddPlaylist: () => _goTo(2)),
      PlaylistsTab(onOpenChannels: () => _goTo(1)),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _index, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goTo,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.directions_car), label: 'Araç ekranı'),
          NavigationDestination(icon: Icon(Icons.live_tv), label: 'Kanallar'),
          NavigationDestination(icon: Icon(Icons.playlist_play), label: 'Listeler'),
        ],
      ),
    );
  }
}
