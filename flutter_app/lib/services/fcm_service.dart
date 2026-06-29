import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../models/message.dart';
import 'api_service.dart';
import 'inbox_store.dart';
import 'notification_service.dart';

@pragma('vm:entry-point')
Future<void> _bgHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final msg = _parse(message);
  if (msg == null) return;
  await InboxStore.instance.load();
  InboxStore.instance.add(msg);
  // System already shows the notification for background notification+data messages
}

BeamMessage? _parse(RemoteMessage message) {
  final d = message.data;
  if (d.isEmpty) return null;
  return BeamMessage(
    id:         d['id']          ?? '',
    fromDevice: d['from_device'] ?? '',
    channelId:  d['channel_id']  ?? '',
    msgType:    d['msg_type']    ?? 'text',
    content:    d['content']     ?? '',
    filename:   d['filename'],
    createdAt:  double.tryParse(d['created_at'] ?? '') ?? (DateTime.now().millisecondsSinceEpoch / 1000),
  );
}

class FcmService {
  static final FcmService instance = FcmService._();
  FcmService._();

  Future<void> init() async {
    if (!Platform.isAndroid) return;

    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_bgHandler);

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);

    final token = await messaging.getToken();
    if (token != null) {
      await ApiService.instance.register(pushToken: token).catchError((_) {});
    }

    FirebaseMessaging.onMessage.listen((RemoteMessage msg) async {
      final m = _parse(msg);
      if (m == null) return;
      InboxStore.instance.add(m);
      await NotificationService.instance.showFromMac(m);
    });

    messaging.onTokenRefresh.listen((t) {
      ApiService.instance.register(pushToken: t).catchError((_) {});
    });
  }
}
