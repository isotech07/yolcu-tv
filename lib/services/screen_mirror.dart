import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum MirrorQuality {
  saver('Tasarruf', 960, 2000000, 24),
  balanced('Dengeli', 1280, 4000000, 30),
  high('Yüksek', 1920, 8000000, 30);

  const MirrorQuality(this.label, this.maxSize, this.bitrate, this.fps);
  final String label;
  final int maxSize;
  final int bitrate;
  final int fps;
}

/// Telefon ekranını yakalayan yerel (Android) koda köprü.
/// Kareler [frames] akışından çıkar; araç sunucusu bunları tarayıcıya iletir.
class ScreenMirror extends ChangeNotifier {
  ScreenMirror() {
    if (!supported) return;
    _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    _method.invokeMethod<bool>('isRunning').then((v) {
      running = v ?? false;
      notifyListeners();
    }).catchError((_) {});
  }

  static const _method = MethodChannel('yolcutv/screen');
  static const _events = EventChannel('yolcutv/screen/events');

  final _frames = StreamController<Uint8List>.broadcast();
  final _resets = StreamController<void>.broadcast();
  StreamSubscription<dynamic>? _sub;

  bool running = false;
  bool starting = false;
  String? lastError;
  MirrorQuality quality = MirrorQuality.balanced;

  bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// iPhone'da görüntüyü yayın uzantısı kendi sunucusundan (8090) verir,
  /// çünkü iOS ana uygulamayı arka planda askıya alır. Android'de ana sunucu (8080) kullanılır.
  static const iosMirrorPort = 8090;
  int? get externalPort => !kIsWeb && Platform.isIOS ? iosMirrorPort : null;

  /// iOS'ta kalite uzantı içinde sabittir (Dengeli).
  bool get qualitySelectable => !kIsWeb && Platform.isAndroid;

  Stream<Uint8List> get frames => _frames.stream;
  Stream<void> get resets => _resets.stream;

  void _onEvent(dynamic e) {
    if (e is Uint8List) {
      _frames.add(e);
      return;
    }
    if (e is String) {
      if (e == 'started') {
        running = true;
        lastError = null;
      } else if (e == 'stopped') {
        running = false;
      } else if (e == 'reset') {
        _resets.add(null);
        return;
      } else if (e.startsWith('error:')) {
        lastError = e.substring(6);
        running = false;
      }
      notifyListeners();
    }
  }

  void setQuality(MirrorQuality q) {
    quality = q;
    notifyListeners();
  }

  /// Android: "ekranınız kaydedilecek" izin penceresini açar; izin verilmezse false döner.
  /// iOS: sistemin "Yayını Başlat" penceresini açar; yayın başlayınca "started" olayı gelir.
  Future<bool> start() async {
    if (!supported || running || starting) return running;
    starting = true;
    lastError = null;
    notifyListeners();
    try {
      final ok = await _method.invokeMethod<bool>('start', {
        'maxSize': quality.maxSize,
        'bitrate': quality.bitrate,
        'fps': quality.fps,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      lastError = e.message;
      return false;
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (!supported) return;
    await _method.invokeMethod('stop');
  }

  void requestKeyFrame() {
    if (!supported || !running) return;
    _method.invokeMethod('requestKeyFrame').catchError((_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _frames.close();
    _resets.close();
    super.dispose();
  }
}
