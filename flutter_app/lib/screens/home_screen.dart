import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/config.dart';
import '../services/inbox_store.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _textCtrl = TextEditingController();
  bool _sending    = false;
  String _feedback = '';
  bool _sseConnected = false;
  double? _uploadProgress; // null = not uploading, 0.0-1.0 = progress

  @override
  void initState() {
    super.initState();
    InboxStore.instance.addListener(_refresh);
    ApiService.instance.connectionState.addListener(_onConnectionChange);
  }

  @override
  void dispose() {
    InboxStore.instance.removeListener(_refresh);
    ApiService.instance.connectionState.removeListener(_onConnectionChange);
    _textCtrl.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});
  void _onConnectionChange() =>
      setState(() => _sseConnected = ApiService.instance.connectionState.value);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('Beam'),
          const SizedBox(width: 8),
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _sseConnected ? Colors.green : Colors.red,
            ),
          ),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
          if (InboxStore.instance.messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => InboxStore.instance.clear(),
            ),
        ],
      ),
      body: Column(children: [
        _buildSendPanel(),
        const Divider(height: 1),
        Expanded(child: _buildInbox()),
      ]),
    );
  }

  Widget _buildSendPanel() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _textCtrl,
          maxLines: 3,
          minLines: 2,
          decoration: InputDecoration(
            hintText: '输入要发送的内容…',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.all(10),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _sending ? null : _sendText,
              icon: const Icon(Icons.send, size: 18),
              label: const Text('发送文字'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _sending ? null : _sendFile,
            icon: const Icon(Icons.attach_file, size: 18),
            label: const Text('发送文件'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _sending ? null : _sendClipboard,
            icon: const Icon(Icons.content_paste, size: 18),
            label: const Text('剪贴板'),
          ),
        ]),
        if (_uploadProgress != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              LinearProgressIndicator(value: _uploadProgress),
              const SizedBox(height: 2),
              Text('上传中 ${((_uploadProgress ?? 0) * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
          )
        else if (_feedback.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_feedback,
                style: TextStyle(
                    fontSize: 12,
                    color: _feedback.startsWith('✓')
                        ? Colors.green
                        : Colors.red)),
          ),
      ]),
    );
  }

  Widget _buildInbox() {
    final msgs = InboxStore.instance.messages;
    if (msgs.isEmpty) {
      return const Center(
        child: Text('收件箱为空\n来自对方设备的推送会出现在这里',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.separated(
      itemCount: msgs.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) => _MessageTile(msg: msgs[i]),
    );
  }

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() { _sending = true; _feedback = ''; });
    try {
      await ApiService.instance.sendText(text);
      setState(() { _textCtrl.clear(); _feedback = '✓ 已发送'; });
    } catch (e) {
      setState(() { _feedback = '✗ 发送失败: $e'; });
    } finally {
      setState(() => _sending = false);
    }
  }

  Future<void> _sendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final path = file.path;
    if (path == null) return;
    setState(() { _sending = true; _feedback = ''; _uploadProgress = 0.0; });
    try {
      await ApiService.instance.sendFile(path, file.name, onProgress: (p) {
        setState(() => _uploadProgress = p);
      });
      setState(() { _feedback = '✓ 文件已发送: ${file.name}'; _uploadProgress = null; });
    } catch (e) {
      setState(() { _feedback = '✗ 发送失败: $e'; _uploadProgress = null; });
    } finally {
      setState(() => _sending = false);
    }
  }

  Future<void> _sendClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _feedback = '剪贴板为空');
      return;
    }
    setState(() { _sending = true; _feedback = ''; });
    try {
      await ApiService.instance.sendText(text);
      setState(() { _feedback = '✓ 剪贴板已发送'; });
    } catch (e) {
      setState(() { _feedback = '✗ 发送失败: $e'; });
    } finally {
      setState(() => _sending = false);
    }
  }

  void _openSettings() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }
}

class _MessageTile extends StatelessWidget {
  final BeamMessage msg;
  const _MessageTile({required this.msg});

  @override
  Widget build(BuildContext context) {
    final isText = msg.msgType == 'text';
    return ListTile(
      leading: Icon(
        isText ? Icons.text_snippet_outlined : Icons.attach_file,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(
        isText ? msg.content : (msg.filename ?? '文件'),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '来自 ${msg.fromDevice} · ${_timeAgo(msg.time)}',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: msg.msgType == 'text'
          ? IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: msg.content));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制到剪贴板'),
                        duration: Duration(seconds: 1)));
              },
            )
          : IconButton(
              icon: const Icon(Icons.download, size: 18),
              onPressed: () => _downloadFile(context, msg),
            ),
      onLongPress: () => InboxStore.instance.remove(msg.id),
    );
  }

  static Future<void> _downloadFile(BuildContext context, BeamMessage msg) async {
    final filename = msg.filename ?? 'file';
    if (msg.content.startsWith('https://')) {
      // GoFile URL — open in browser
      final uri = Uri.parse(msg.content);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('无法打开链接')));
        }
      }
      return;
    }
    try {
      final path = await ApiService.instance.downloadFile(msg.content, filename);
      await Share.shareXFiles([XFile(path)], text: filename);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('下载失败: $e')));
      }
    }
  }

  String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24)   return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }
}

// ── Settings ──────────────────────────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _channelCtrl;

  @override
  void initState() {
    super.initState();
    _channelCtrl = TextEditingController(text: Config.channelId);
  }

  @override
  void dispose() {
    _channelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          TextField(
            controller: _channelCtrl,
            decoration: const InputDecoration(
              labelText: '频道 (Channel)',
              hintText: 'default',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '所有设置相同频道的设备互相收发消息',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ]),
      ),
    );
  }

  Future<void> _save() async {
    await Config.setChannelId(_channelCtrl.text.trim().isEmpty
        ? 'default'
        : _channelCtrl.text.trim());
    // Re-register and reconnect SSE with new channel
    ApiService.instance.disconnectSSE();
    ApiService.instance.register().catchError((_) {});
    if (mounted) Navigator.pop(context);
  }
}
