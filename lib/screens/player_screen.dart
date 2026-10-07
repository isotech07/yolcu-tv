import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../models/channel.dart';
import '../services/car_server.dart';
import '../services/epg_service.dart';
import '../services/net.dart';
import '../state/app_state.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.playlist, required this.index});
  final List<Channel> playlist;
  final int index;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player(
    configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024),
  );
  late final VideoController _video = VideoController(_player);
  late int _index = widget.index;
  StreamSubscription<String>? _errors;

  Channel get _channel => widget.playlist[_index];

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _errors = _player.stream.error.listen((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yayın açılamadı. Kaynak şu an yanıt vermiyor olabilir.\n$e')),
      );
    });
    _open();
  }

  Future<void> _open() async {
    final ch = _channel;
    context.read<AppState>().markRecent(ch.id);
    await _player.open(Media(ch.url, httpHeaders: {
      'User-Agent': Net.defaultUserAgent,
      ...ch.headers,
    }));
  }

  void _zap(int delta) {
    setState(() => _index = (_index + delta) % widget.playlist.length);
    _open();
  }

  void _sendToCar() {
    final car = context.read<CarServer>();
    car.playOnCar(_channel);
    _player.pause();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${_channel.name} araç ekranına gönderildi')),
    );
  }

  @override
  void dispose() {
    _errors?.cancel();
    _player.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final carRunning = context.select<CarServer, bool>((c) => c.running);
    final now = context.select<EpgService, String?>((e) => e.nowNext(_channel.tvgId).now?.title);

    final topBar = <Widget>[
      MaterialCustomButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.pop(context),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (now != null)
              Text(now, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      ),
      if (carRunning)
        MaterialCustomButton(icon: const Icon(Icons.directions_car), onPressed: _sendToCar),
      MaterialCustomButton(icon: const Icon(Icons.skip_previous), onPressed: () => _zap(-1)),
      MaterialCustomButton(icon: const Icon(Icons.skip_next), onPressed: () => _zap(1)),
    ];

    final theme = MaterialVideoControlsThemeData(
      topButtonBar: topBar,
      seekBarMargin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      bottomButtonBarMargin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: MaterialVideoControlsTheme(
        normal: theme,
        fullscreen: theme,
        child: Video(controller: _video),
      ),
    );
  }
}
