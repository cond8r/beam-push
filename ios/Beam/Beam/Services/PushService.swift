import UIKit
import UserNotifications

class PushService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushService()

    func requestPermission() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
        handlePayload(notification.request.content.userInfo)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler handler: @escaping () -> Void) {
        handlePayload(response.notification.request.content.userInfo)
        handler()
    }

    func handlePayload(_ userInfo: [AnyHashable: Any]) {
        guard let beam = userInfo["beam"] as? [String: Any] else { return }
        let msgType    = beam["msg_type"]    as? String ?? "text"
        let content    = beam["content"]     as? String ?? ""
        let msgID      = beam["id"]          as? String ?? ""
        let fromDevice = beam["from_device"] as? String ?? ""
        let channelId  = beam["channel_id"]  as? String ?? ""
        let filename   = beam["filename"]    as? String

        if msgType == "text" {
            UIPasteboard.general.string = content
            InboxStore.shared.add(BeamMessage(
                id: msgID, from_device: fromDevice, channel_id: channelId,
                msg_type: "text", content: content,
                filename: nil, created_at: Date().timeIntervalSince1970
            ))
        } else if msgType == "file" {
            let name = filename ?? "file"
            // content is now a file_id — download from server
            Task {
                let fileId = content
                let urlStr = "\(Beam.server)/download/\(fileId)?auth_token=\(Beam.authToken)&filename=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)"
                guard let url = URL(string: urlStr),
                      let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? data.write(to: dest)
                InboxStore.shared.add(BeamMessage(
                    id: msgID, from_device: fromDevice, channel_id: channelId,
                    msg_type: "file", content: dest.path,
                    filename: name, created_at: Date().timeIntervalSince1970
                ))
            }
        }

        Task { try? await APIService.shared.ack(messageID: msgID) }
    }
}
