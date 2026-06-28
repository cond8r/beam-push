// FCM disabled — using SSE for push
class FcmService {
  static final FcmService instance = FcmService._();
  FcmService._();
  Future<void> init() async {}
}
