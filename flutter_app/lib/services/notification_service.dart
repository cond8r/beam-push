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

    // Request permissions on macOS
    if (Platform.isMacOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
    }
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
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
