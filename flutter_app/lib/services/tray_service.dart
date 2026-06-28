// Tray support disabled — desktop-only packages removed for Android build
typedef SendTextCallback = Future<void> Function(String text);
typedef SendFileCallback = Future<void> Function();

class TrayService {
  static final TrayService instance = TrayService._();
  TrayService._();

  Future<void> init({
    required SendTextCallback onSendText,
    required SendFileCallback onSendFile,
  }) async {}

  void setStatus(bool connected) {}
}
