import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/message.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const macSettings     = DarwinInitializationSettings();

    await _plugin.initialize(
      const InitializationSettings(
        android: androidSettings,
        macOS:   macSettings,
      ),
    );

    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      // Create the channel immediately so FCM background notifications have somewhere to land
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        'beam_channel',
        'Beam 推送',
        description: '来自 Mac 的推送内容',
        importance: Importance.high,
      ));
    }
    if (Platform.isMacOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
    }
  }

  Future<void> showFromMac(BeamMessage msg) async {
    final title = '📲 来自 ${msg.fromDevice.isNotEmpty ? msg.fromDevice : "其他设备"}';
    final body  = msg.msgType == 'file'
        ? '📎 ${msg.filename ?? "文件"}'
        : msg.content.length > 60
            ? '${msg.content.substring(0, 60)}…'
            : msg.content;

    await _plugin.show(
      msg.id.hashCode,
      title,
      body,
      NotificationDetails(
        android: const AndroidNotificationDetails(
          'beam_channel', 'Beam 推送',
          channelDescription: '来自 Mac 的推送内容',
          importance: Importance.high,
          priority: Priority.high,
        ),
        macOS: const DarwinNotificationDetails(sound: 'default'),
      ),
    );
  }
}
