class BeamMessage {
  final String id;
  final String fromDevice;
  final String channelId;
  final String msgType;
  final String content;
  final String? filename;
  final double createdAt;

  BeamMessage({
    required this.id,
    required this.fromDevice,
    required this.channelId,
    required this.msgType,
    required this.content,
    this.filename,
    required this.createdAt,
  });

  factory BeamMessage.fromJson(Map<String, dynamic> j) => BeamMessage(
        id:         j['id']          ?? '',
        fromDevice: j['from_device'] ?? '',
        channelId:  j['channel_id']  ?? '',
        msgType:    j['msg_type']    ?? 'text',
        content:    j['content']     ?? '',
        filename:   j['filename'],
        createdAt:  (j['created_at'] as num?)?.toDouble() ?? 0,
      );

  DateTime get time => DateTime.fromMillisecondsSinceEpoch((createdAt * 1000).toInt());
}
