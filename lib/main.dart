import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/car_server.dart';
import 'services/epg_service.dart';
import 'services/screen_mirror.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final app = AppState();
  await app.init();
  final mirror = ScreenMirror();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<EpgService>.value(value: app.epg),
        ChangeNotifierProvider<ScreenMirror>.value(value: mirror),
        ChangeNotifierProvider<CarServer>(create: (_) => CarServer(app, mirror)),
      ],
      child: const YolcuTvApp(),
    ),
  );
}

class YolcuTvApp extends StatelessWidget {
  const YolcuTvApp({super.key});

  static const night = Color(0xFF0F1E33);
  static const panel = Color(0xFF172A45);
  static const lane = Color(0xFFF4B400);

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: lane,
      brightness: Brightness.dark,
    ).copyWith(
      primary: lane,
      onPrimary: const Color(0xFF1A1300),
      surface: night,
      surfaceContainer: panel,
    );
    return MaterialApp(
      title: 'YolcuTV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: night,
        useMaterial3: true,
        cardTheme: const CardThemeData(color: panel, margin: EdgeInsets.zero),
        appBarTheme: const AppBarTheme(backgroundColor: night, centerTitle: false),
      ),
      home: const HomeScreen(),
    );
  }
}
