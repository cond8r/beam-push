import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/message.dart';

class InboxStore extends ChangeNotifier {
  static final InboxStore instance = InboxStore._();
  InboxStore._();

  static const _key = 'beam_inbox_v1';
  static const _maxMessages = 200;

  final List<BeamMessage> _messages = [];
  List<BeamMessage> get messages => List.unmodifiable(_messages);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? [];
    _messages.clear();
    for (final s in raw) {
      try {
        _messages.add(BeamMessage.fromJson(jsonDecode(s)));
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _messages.take(_maxMessages).map((m) => jsonEncode({
      'id':          m.id,
      'from_device': m.fromDevice,
      'channel_id':  m.channelId,
      'msg_type':    m.msgType,
      'content':     m.content,
      'filename':    m.filename,
      'created_at':  m.createdAt,
    })).toList();
    await prefs.setStringList(_key, list);
  }

  void add(BeamMessage msg) {
    if (_messages.any((m) => m.id == msg.id)) return;
    _messages.insert(0, msg);
    if (_messages.length > _maxMessages) _messages.removeLast();
    notifyListeners();
    _save();
  }

  void clear() {
    _messages.clear();
    notifyListeners();
    _save();
  }

  void remove(String id) {
    _messages.removeWhere((m) => m.id == id);
    notifyListeners();
    _save();
  }
}
