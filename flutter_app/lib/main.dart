import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/message.dart';
import 'services/api_service.dart';
import 'services/config.dart';
import 'services/fcm_service.dart';
import 'services/inbox_store.dart';
import 'services/notification_service.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Config.init();
  await NotificationService.instance.init();
  await InboxStore.instance.load();
  runApp(const BeamApp());
  // Firebase init requires network — run after UI is shown to avoid blocking splash
  if (Platform.isAndroid) {
    FcmService.instance.init().catchError((_) {});
  }
}

class BeamApp extends StatefulWidget {
  const BeamApp({super.key});
  @override
  State<BeamApp> createState() => _BeamAppState();
}

class _BeamAppState extends State<BeamApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startServices();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ApiService.instance.disconnectSSE();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _connectSSE();
    } else if (state == AppLifecycleState.paused) {
      ApiService.instance.disconnectSSE();
    }
  }

  void _startServices() {
    // Android: FcmService.init() in main() already called register() with push token
    if (!Platform.isAndroid) {
      ApiService.instance.register().catchError((_) {});
    }
    _connectSSE();
  }

  void _connectSSE() {
    ApiService.instance.connectSSE().listen((BeamMessage msg) async {
      InboxStore.instance.add(msg);
      await NotificationService.instance.showFromMac(msg);
      if (msg.msgType == 'text') {
        await Clipboard.setData(ClipboardData(text: msg.content));
      }
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Beam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
