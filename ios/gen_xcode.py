#!/usr/bin/env python3
"""生成完整 Beam iOS Xcode 项目结构"""
import os, uuid, json
from pathlib import Path

BASE   = Path(__file__).parent / "Beam"
BUNDLE = "com.fangduo.beam"
SERVER = "http://82.156.210.133:8899"
TOKEN  = "42bb6684ae6c90d74e546c4bfa99976f"

def mkdirs(*dirs):
    for d in dirs:
        d.mkdir(parents=True, exist_ok=True)

mkdirs(
    BASE / "Beam",
    BASE / "Beam/Views",
    BASE / "Beam/Models",
    BASE / "Beam/Services",
    BASE / "BeamShare",
)

# ── Constants.swift ───────────────────────────────────────────────────────────
(BASE / "Beam/Constants.swift").write_text(f'''import Foundation

enum Beam {{
    static let server    = "{SERVER}"
    static let authToken = "{TOKEN}"
    static let deviceID  = "ios-" + UIDevice.current.identifierForVendor!.uuidString
}}
''')

# ── Message.swift ─────────────────────────────────────────────────────────────
(BASE / "Beam/Models/Message.swift").write_text('''import Foundation

struct BeamMessage: Codable, Identifiable {
    var id: String
    var from_type: String
    var to_type: String
    var msg_type: String   // "text" | "file"
    var content: String
    var filename: String?
    var created_at: Double
}
''')

# ── APIService.swift ──────────────────────────────────────────────────────────
(BASE / "Beam/Services/APIService.swift").write_text(f'''import Foundation
import UIKit

class APIService {{
    static let shared = APIService()

    func register(pushToken: String?) async throws {{
        var body: [String: Any] = [
            "device_id":   Beam.deviceID,
            "device_type": "ios",
            "auth_token":  Beam.authToken,
        ]
        if let t = pushToken {{ body["push_token"] = t }}
        try await post("/register", body: body)
    }}

    func send(text: String) async throws {{
        try await post("/send", body: [
            "from_device": Beam.deviceID,
            "msg_type":    "text",
            "content":     text,
            "auth_token":  Beam.authToken,
        ])
    }}

    func sendFile(data: Data, filename: String) async throws {{
        let b64 = data.base64EncodedString()
        try await post("/send", body: [
            "from_device": Beam.deviceID,
            "msg_type":    "file",
            "content":     b64,
            "filename":    filename,
            "auth_token":  Beam.authToken,
        ])
    }}

    func ack(messageID: String) async throws {{
        try await post("/ack", body: [
            "message_id": messageID,
            "device_id":  Beam.deviceID,
            "auth_token": Beam.authToken,
        ])
    }}

    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> Data {{
        var req = URLRequest(url: URL(string: Beam.server + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {{
            throw URLError(.badServerResponse)
        }}
        return data
    }}
}}
''')

# ── PushService.swift ─────────────────────────────────────────────────────────
(BASE / "Beam/Services/PushService.swift").write_text('''import UIKit
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

    // Called when notification received while app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
        handlePayload(notification.request.content.userInfo)
    }

    // Called when user taps notification
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler handler: @escaping () -> Void) {
        handlePayload(response.notification.request.content.userInfo)
        handler()
    }

    func handlePayload(_ userInfo: [AnyHashable: Any]) {
        guard let beam = userInfo["beam"] as? [String: Any] else { return }
        let msgType = beam["msg_type"] as? String ?? "text"
        let content = beam["content"] as? String ?? ""
        let msgID   = beam["id"] as? String ?? ""
        let filename = beam["filename"] as? String

        if msgType == "text" {
            UIPasteboard.general.string = content
            InboxStore.shared.add(BeamMessage(
                id: msgID, from_type: "mac", to_type: "ios",
                msg_type: "text", content: content,
                filename: nil, created_at: Date().timeIntervalSince1970
            ))
        } else if msgType == "file", let data = Data(base64Encoded: content) {
            let name = filename ?? "file"
            let url  = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url)
            InboxStore.shared.add(BeamMessage(
                id: msgID, from_type: "mac", to_type: "ios",
                msg_type: "file", content: url.path,
                filename: name, created_at: Date().timeIntervalSince1970
            ))
        }

        Task { try? await APIService.shared.ack(messageID: msgID) }
    }
}
''')

# ── InboxStore.swift ──────────────────────────────────────────────────────────
(BASE / "Beam/Services/InboxStore.swift").write_text('''import Foundation

class InboxStore: ObservableObject {
    static let shared = InboxStore()
    @Published var messages: [BeamMessage] = []

    func add(_ msg: BeamMessage) {
        DispatchQueue.main.async {
            self.messages.insert(msg, at: 0)
        }
    }

    func clear() {
        messages.removeAll()
    }
}
''')

# ── ContentView.swift ─────────────────────────────────────────────────────────
(BASE / "Beam/Views/ContentView.swift").write_text('''import SwiftUI

struct ContentView: View {
    @EnvironmentObject var inbox: InboxStore
    @State private var sendText  = ""
    @State private var sending   = false
    @State private var feedback  = ""
    @State private var showPicker = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Send area
                VStack(spacing: 10) {
                    TextEditor(text: $sendText)
                        .frame(height: 80)
                        .padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
                        .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button(action: sendCurrentText) {
                            Label("发送文字", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sendText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)

                        Button(action: { showPicker = true }) {
                            Label("发送文件", systemImage: "doc.fill")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !feedback.isEmpty {
                        Text(feedback).font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical)

                Divider()

                // Inbox
                List {
                    ForEach(inbox.messages) { msg in
                        MessageRow(msg: msg)
                    }
                    .onDelete { idx in inbox.messages.remove(atOffsets: idx) }
                }
                .listStyle(.plain)
                .overlay {
                    if inbox.messages.isEmpty {
                        Text("收件箱为空\\n来自 Mac 的推送会出现在这里")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Beam")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { inbox.clear() }
                        .disabled(inbox.messages.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            FilePicker { url in sendFile(url: url) }
        }
    }

    func sendCurrentText() {
        let text = sendText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            do {
                try await APIService.shared.send(text: text)
                await MainActor.run {
                    sendText = ""
                    feedback = "✓ 已发送"
                    sending  = false
                }
            } catch {
                await MainActor.run {
                    feedback = "✗ 发送失败"
                    sending  = false
                }
            }
        }
    }

    func sendFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        Task {
            do {
                try await APIService.shared.sendFile(data: data, filename: url.lastPathComponent)
                await MainActor.run { feedback = "✓ 文件已发送" }
            } catch {
                await MainActor.run { feedback = "✗ 发送失败" }
            }
        }
    }
}

struct MessageRow: View {
    let msg: BeamMessage
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: msg.msg_type == "file" ? "doc.fill" : "text.bubble.fill")
                .foregroundColor(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                if msg.msg_type == "text" {
                    Text(msg.content)
                        .font(.body)
                        .lineLimit(4)
                } else {
                    Text(msg.filename ?? "文件").font(.body)
                    if let path = msg.msg_type == "file" ? msg.content : nil {
                        ShareLink(item: URL(fileURLWithPath: path)) {
                            Label("分享", systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                    }
                }
                Text(Date(timeIntervalSince1970: msg.created_at), style: .relative)
                    .font(.caption2).foregroundColor(.secondary)
            }

            Spacer()

            if msg.msg_type == "text" {
                Button {
                    UIPasteboard.general.string = msg.content
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundColor(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct FilePicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}
''')

# ── AppDelegate.swift ─────────────────────────────────────────────────────────
(BASE / "Beam/BeamApp.swift").write_text(f'''import SwiftUI
import UIKit

@main
struct BeamApp: App {{
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var inbox = InboxStore.shared

    var body: some Scene {{
        WindowGroup {{
            ContentView()
                .environmentObject(inbox)
        }}
    }}
}}

class AppDelegate: NSObject, UIApplicationDelegate {{
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {{
        PushService.shared.requestPermission()
        return true
    }}

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {{
        let token = deviceToken.map {{ String(format: "%02x", $0) }}.joined()
        Task {{ try? await APIService.shared.register(pushToken: token) }}
    }}

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler handler: @escaping (UIBackgroundFetchResult) -> Void) {{
        PushService.shared.handlePayload(userInfo)
        handler(.newData)
    }}
}}
''')

# ── Share Extension ───────────────────────────────────────────────────────────
(BASE / "BeamShare/ShareViewController.swift").write_text(f'''import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {{
    private let server    = "{SERVER}"
    private let authToken = "{TOKEN}"

    override func viewDidLoad() {{
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first else {{
            finish(); return
        }}

        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) ||
           provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {{
            provider.loadItem(forTypeIdentifier: UTType.url.identifier as String, options: nil) {{ data, _ in
                let text: String
                if let url = data as? URL {{ text = url.absoluteString }}
                else if let str = data as? String {{ text = str }}
                else {{ self.finish(); return }}
                Task {{ await self.sendText(text); self.finish() }}
            }}
        }} else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {{
            provider.loadItem(forTypeIdentifier: UTType.data.identifier as String, options: nil) {{ data, _ in
                guard let url = data as? URL,
                      let fileData = try? Data(contentsOf: url) else {{
                    self.finish(); return
                }}
                Task {{ await self.sendFile(fileData, name: url.lastPathComponent); self.finish() }}
            }}
        }} else {{
            finish()
        }}
    }}

    func sendText(_ text: String) async {{
        guard let deviceID = await deviceID() else {{ return }}
        _ = try? await post("/send", body: [
            "from_device": deviceID,
            "msg_type": "text",
            "content": text,
            "auth_token": authToken,
        ])
    }}

    func sendFile(_ data: Data, name: String) async {{
        guard let deviceID = await deviceID() else {{ return }}
        _ = try? await post("/send", body: [
            "from_device": deviceID,
            "msg_type": "file",
            "content": data.base64EncodedString(),
            "filename": name,
            "auth_token": authToken,
        ])
    }}

    func deviceID() async -> String? {{
        await MainActor.run {{
            "ios-" + (UIDevice.current.identifierForVendor?.uuidString ?? "unknown")
        }}
    }}

    func post(_ path: String, body: [String: Any]) async throws -> Data {{
        var req = URLRequest(url: URL(string: server + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }}

    func finish() {{
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }}
}}
''')

# ── Share Extension Info.plist ────────────────────────────────────────────────
(BASE / "BeamShare/Info.plist").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>NSExtensionActivationRule</key>
            <dict>
                <key>NSExtensionActivationSupportsText</key>
                <true/>
                <key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
                <integer>1</integer>
                <key>NSExtensionActivationSupportsFileWithMaxCount</key>
                <integer>1</integer>
            </dict>
        </dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.share-services</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
    </dict>
</dict>
</plist>
''')

# ── Main app Info.plist ───────────────────────────────────────────────────────
(BASE / "Beam/Info.plist").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleDisplayName</key>
    <string>Beam</string>
    <key>CFBundleIdentifier</key>
    <string>{BUNDLE}</string>
    <key>CFBundleName</key>
    <string>Beam</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <false/>
    </dict>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Beam 需要访问相册以发送图片</string>
    <key>UIBackgroundModes</key>
    <array>
        <string>remote-notification</string>
        <string>fetch</string>
    </array>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
</dict>
</plist>
''')

print("✓ Beam iOS source files generated at:", BASE)
print(f"  Bundle ID : {BUNDLE}")
print(f"  Server    : {SERVER}")
print()
print("下一步：")
print("1. 在 Xcode 中 File → New → Project，选 iOS App，名称 Beam")
print("2. Bundle ID 设为 com.fangduo.beam")
print("3. 把生成的 Swift 文件拖入对应 target")
print("4. 添加 BeamShare Extension target")
print("5. 开启 Push Notifications capability")
print("6. 在 Apple Developer Portal 创建 APNs Auth Key (p8)，填入 server 的 systemd 配置")
