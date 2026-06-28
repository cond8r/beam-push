import SwiftUI

struct ContentView: View {
    @EnvironmentObject var inbox: InboxStore
    @State private var sendText      = ""
    @State private var sending       = false
    @State private var feedback      = ""
    @State private var showPicker    = false
    @State private var showSettings  = false
    @State private var uploadProgress: Double? = nil

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

                    if let progress = uploadProgress {
                        VStack(spacing: 4) {
                            ProgressView(value: progress)
                                .padding(.horizontal)
                            Text("上传中 \(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if !feedback.isEmpty {
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
                        Text("收件箱为空\n来自其他设备的推送会出现在这里")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Beam · \(Beam.channelId)")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { inbox.clear() }
                        .disabled(inbox.messages.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            FilePicker { url in sendFile(url: url) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
        Task {
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                try await APIService.shared.sendFile(
                    fileURL: url,
                    filename: url.lastPathComponent,
                    onProgress: { p in
                        Task { @MainActor in self.uploadProgress = p }
                    }
                )
                await MainActor.run {
                    uploadProgress = nil
                    feedback = "✓ 文件已发送"
                }
            } catch {
                await MainActor.run {
                    uploadProgress = nil
                    feedback = "✗ 发送失败"
                }
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
            } else if msg.content.hasPrefix("https://") {
                Button {
                    UIApplication.shared.open(URL(string: msg.content)!)
                } label: {
                    Image(systemName: "safari")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            } else {
                ShareLink(
                    item: URL(fileURLWithPath: msg.content),
                    preview: SharePreview(msg.filename ?? "文件", image: Image(systemName: "doc"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// ── Settings ──────────────────────────────────────────────────────────────────
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var channel = Beam.channelId

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("频道名称", text: $channel)
                        .autocapitalization(.none)
                } header: {
                    Text("频道")
                } footer: {
                    Text("所有设置相同频道的设备互相收发消息")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Beam.channelId = channel.isEmpty ? Beam.defaultChannel : channel
                        Task { try? await APIService.shared.register(pushToken: nil) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
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
