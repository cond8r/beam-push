import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'config.dart';
import '../models/message.dart';

class ApiService {
  static final ApiService instance = ApiService._();
  ApiService._();

  StreamController<BeamMessage>? _sseController;
  io.HttpClient? _sseClient;
  bool _sseRunning = false;
  int _sseGeneration = 0;
  final connectionState = ValueNotifier<bool>(false);

  Uri _uri(String path) => Uri.parse('${Config.server}$path');

  Map<String, String> get _headers => {'Content-Type': 'application/json'};

  Future<void> register({String? pushToken}) async {
    await http.post(
      _uri('/register'),
      headers: _headers,
      body: jsonEncode({
        'device_id':   Config.deviceId,
        'channel_id':  Config.channelId,
        'device_type': _deviceType(),
        'push_token':  pushToken,
        'auth_token':  Config.token,
      }),
    );
  }

  Future<void> sendText(String text) async {
    final res = await http.post(
      _uri('/send'),
      headers: _headers,
      body: jsonEncode({
        'from_device': Config.deviceId,
        'channel_id':  Config.channelId,
        'msg_type':    'text',
        'content':     text,
        'auth_token':  Config.token,
      }),
    );
    if (res.statusCode != 200) throw Exception('Send failed: ${res.body}');
  }

  static const _goFileThreshold = 50 * 1024 * 1024; // 50 MB

  Future<void> sendFile(String filePath, String filename, {void Function(double)? onProgress}) async {
    final size = await io.File(filePath).length();
    if (size > _goFileThreshold) {
      // Large file: upload to GoFile, send URL via Beam
      final downloadUrl = await _uploadToGoFile(filePath, filename, onProgress: onProgress);
      final res = await http.post(
        _uri('/send'),
        headers: _headers,
        body: jsonEncode({
          'from_device': Config.deviceId,
          'channel_id':  Config.channelId,
          'msg_type':    'file',
          'content':     downloadUrl,
          'filename':    filename,
          'auth_token':  Config.token,
        }),
      );
      if (res.statusCode != 200) throw Exception('Send failed: ${res.body}');
    } else {
      // Small file: upload directly to Beam server with progress tracking
      final boundary = 'BeamBoundary${DateTime.now().millisecondsSinceEpoch}';
      final file = io.File(filePath);
      final fileSize = await file.length();
      final header = utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$filename"\r\nContent-Type: application/octet-stream\r\n\r\n',
      );
      final fieldPrefix = utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="from_device"\r\n\r\n${Config.deviceId}\r\n'
        '--$boundary\r\nContent-Disposition: form-data; name="channel_id"\r\n\r\n${Config.channelId}\r\n'
        '--$boundary\r\nContent-Disposition: form-data; name="auth_token"\r\n\r\n${Config.token}\r\n',
      );
      final footer = utf8.encode('\r\n--$boundary--\r\n');
      final contentLength = fieldPrefix.length + header.length + fileSize + footer.length;

      final client = io.HttpClient();
      try {
        final req = await client.postUrl(_uri('/upload'));
        req.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
        req.contentLength = contentLength;
        req.add(fieldPrefix);
        req.add(header);
        int bytesSent = 0;
        double lastReported = -1;
        await req.addStream(file.openRead().map((chunk) {
          bytesSent += chunk.length;
          final p = bytesSent / fileSize * 0.95;
          if (p - lastReported >= 0.01) { lastReported = p; onProgress?.call(p); }
          return chunk;
        }));
        req.add(footer);
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        if (resp.statusCode != 200) throw Exception('Upload failed: $body');
        onProgress?.call(1.0);
      } finally {
        client.close();
      }
    }
  }

  Future<String> _uploadToGoFile(String filePath, String filename, {void Function(double)? onProgress}) async {
    // Step 1: get best server
    final serverRes = await http.get(Uri.parse('https://api.gofile.io/servers'));
    if (serverRes.statusCode != 200) throw Exception('GoFile server lookup failed');
    final serverData = jsonDecode(serverRes.body);
    final server = serverData['data']['servers'][0]['name'] as String;

    // Step 2: stream file directly via dart:io HttpClient to avoid buffering OOM
    final boundary = 'BeamBoundary${DateTime.now().millisecondsSinceEpoch}';
    final file = io.File(filePath);
    final fileSize = await file.length();
    final header = utf8.encode(
      '--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$filename"\r\nContent-Type: application/octet-stream\r\n\r\n',
    );
    final footer = utf8.encode('\r\n--$boundary--\r\n');
    final contentLength = header.length + fileSize + footer.length;

    final client = io.HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('https://$server.gofile.io/contents/uploadFile'),
      );
      req.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
      req.contentLength = contentLength;
      req.add(header);
      int bytesSent = 0;
      double lastReported = -1;
      await req.addStream(file.openRead().map((chunk) {
        bytesSent += chunk.length;
        final p = bytesSent / fileSize * 0.95;
        if (p - lastReported >= 0.01) { lastReported = p; onProgress?.call(p); }
        return chunk;
      }));
      req.add(footer);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) throw Exception('GoFile upload failed: $body');
      final data = jsonDecode(body);
      if (data['status'] != 'ok') throw Exception('GoFile error: $body');
      return data['data']['downloadPage'] as String;
    } finally {
      client.close();
    }
  }

  Future<String> downloadFile(String contentOrUrl, String filename) async {
    final Uri url;
    if (contentOrUrl.startsWith('https://')) {
      // GoFile or other direct URL — open in browser instead of downloading
      url = Uri.parse(contentOrUrl);
    } else {
      // Legacy Beam server file
      url = _uri('/download/$contentOrUrl').replace(queryParameters: {
        'auth_token': Config.token,
        'filename': filename,
      });
    }
    final client = http.Client();
    try {
      final request = http.Request('GET', url);
      final response = await client.send(request);
      if (response.statusCode != 200) throw Exception('Download failed: ${response.statusCode}');
      final dir = await getTemporaryDirectory();
      final file = io.File('${dir.path}/$filename');
      final sink = file.openWrite();
      await response.stream.pipe(sink);
      await sink.close();
      return file.path;
    } finally {
      client.close();
    }
  }

  Future<void> ack(String messageId) async {
    await http.post(
      _uri('/ack'),
      headers: _headers,
      body: jsonEncode({
        'message_id': messageId,
        'device_id':  Config.deviceId,
        'auth_token': Config.token,
      }),
    );
  }

  // SSE stream for all platforms
  Stream<BeamMessage> connectSSE() {
    _sseController?.close();
    _sseController = StreamController<BeamMessage>.broadcast();
    _startSSE();
    return _sseController!.stream;
  }

  void _startSSE() async {
    final gen = ++_sseGeneration;
    _sseRunning = true;
    while (_sseRunning && gen == _sseGeneration) {
      io.HttpClient? client;
      try {
        client = io.HttpClient();
        _sseClient = client;
        final req = await client.getUrl(
          _uri('/stream?device_id=${Config.deviceId}&channel_id=${Config.channelId}&auth_token=${Config.token}'),
        );
        req.headers.set('Accept', 'text/event-stream');
        final resp = await req.close();
        connectionState.value = true;

        final buf = StringBuffer();
        await for (final chunk in resp.transform(utf8.decoder)) {
          if (!_sseRunning || gen != _sseGeneration) break;
          buf.write(chunk);
          final str = buf.toString();
          final events = str.split('\n\n');
          buf.clear();
          if (!str.endsWith('\n\n')) buf.write(events.removeLast());
          for (final event in events) {
            for (final line in event.split('\n')) {
              if (line.startsWith('data:')) {
                final raw = line.substring(5).trim();
                if (raw.isNotEmpty) {
                  try {
                    final msg = BeamMessage.fromJson(jsonDecode(raw));
                    _sseController?.add(msg);
                    ack(msg.id).catchError((_) {});
                  } catch (_) {}
                }
              }
            }
          }
        }
      } catch (e) {
        // ignore
      } finally {
        client?.close(force: true);
      }
      connectionState.value = false;
      if (_sseRunning && gen == _sseGeneration) {
        await Future.delayed(const Duration(seconds: 5));
      }
    }
    connectionState.value = false;
  }

  void disconnectSSE() {
    _sseRunning = false;
    _sseClient?.close(force: true);
    _sseController?.close();
    _sseController = null;
  }

  String _deviceType() {
    if (io.Platform.isAndroid) return 'android';
    if (io.Platform.isIOS)     return 'ios';
    if (io.Platform.isWindows) return 'windows';
    if (io.Platform.isMacOS)   return 'mac';
    return 'unknown';
  }
}
