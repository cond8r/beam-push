import Foundation
import UIKit

private class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (Double) -> Void
    init(_ onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

class APIService {
    static let shared = APIService()

    private var _sseRunning = false
    private var _sseTask: Task<Void, Never>?
    private var _sseGeneration = 0
    private var _sseSession: URLSession?

    func register(pushToken: String?) async throws {
        var body: [String: Any] = [
            "device_id":   Beam.deviceID,
            "channel_id":  Beam.channelId,
            "device_type": "ios",
            "auth_token":  Beam.authToken,
        ]
        if let t = pushToken { body["push_token"] = t }
        try await post("/register", body: body)
    }

    func send(text: String) async throws {
        try await post("/send", body: [
            "from_device": Beam.deviceID,
            "channel_id":  Beam.channelId,
            "msg_type":    "text",
            "content":     text,
            "auth_token":  Beam.authToken,
        ])
    }

    private let goFileThreshold: Int = 50 * 1024 * 1024 // 50 MB

    func sendFile(fileURL: URL, filename: String, onProgress: ((Double) -> Void)? = nil) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > goFileThreshold {
            // Large file: upload to GoFile, send URL via Beam
            let downloadURL = try await uploadToGoFile(fileURL: fileURL, filename: filename, onProgress: onProgress)
            try await post("/send", body: [
                "from_device": Beam.deviceID,
                "channel_id":  Beam.channelId,
                "msg_type":    "file",
                "content":     downloadURL,
                "filename":    filename,
                "auth_token":  Beam.authToken,
            ])
        } else {
            // Small file: build multipart in temp file, then stream-upload with progress
            let boundary = UUID().uuidString
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".multipart")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            func appendString(_ s: String) { out.write(s.data(using: .utf8)!) }
            func appendField(_ name: String, _ value: String) {
                appendString("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            appendField("from_device", Beam.deviceID)
            appendField("channel_id",  Beam.channelId)
            appendField("auth_token",  Beam.authToken)
            appendString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            let src = try FileHandle(forReadingFrom: fileURL)
            defer { src.closeFile() }
            while true {
                let chunk = src.readData(ofLength: 1024 * 1024)
                if chunk.isEmpty { break }
                out.write(chunk)
            }
            appendString("\r\n--\(boundary)--\r\n")
            out.closeFile()
            var req = URLRequest(url: URL(string: Beam.server + "/upload")!)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 300
            let session: URLSession
            if let cb = onProgress {
                session = URLSession(configuration: .default, delegate: UploadProgressDelegate(cb), delegateQueue: nil)
            } else {
                session = URLSession.shared
            }
            let (_, resp) = try await session.upload(for: req, fromFile: tempURL)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
        }
    }

    private func uploadToGoFile(fileURL: URL, filename: String, onProgress: ((Double) -> Void)? = nil) async throws -> String {
        // Step 1: get best server
        let serverData = try await URLSession.shared.data(from: URL(string: "https://api.gofile.io/servers")!).0
        guard let serverJSON = try? JSONSerialization.jsonObject(with: serverData) as? [String: Any],
              let data = serverJSON["data"] as? [String: Any],
              let servers = data["servers"] as? [[String: Any]],
              let server = servers.first?["name"] as? String else {
            throw URLError(.badServerResponse)
        }

        // Step 2: build multipart body in temp file (streaming, no full-file memory load)
        let boundary = UUID().uuidString
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        func str(_ s: String) { out.write(s.data(using: .utf8)!) }
        str("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        let src = try FileHandle(forReadingFrom: fileURL)
        defer { src.closeFile() }
        while true {
            let chunk = src.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            out.write(chunk)
        }
        str("\r\n--\(boundary)--\r\n")
        out.closeFile()

        var req = URLRequest(url: URL(string: "https://\(server).gofile.io/contents/uploadFile")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        let session: URLSession
        if let cb = onProgress {
            session = URLSession(configuration: .default, delegate: UploadProgressDelegate(cb), delegateQueue: nil)
        } else {
            session = URLSession.shared
        }
        let (respData, resp) = try await session.upload(for: req, fromFile: tempURL)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let resultData = json["data"] as? [String: Any],
              let downloadPage = resultData["downloadPage"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return downloadPage
    }

    func ack(messageID: String) async throws {
        try await post("/ack", body: [
            "message_id": messageID,
            "device_id":  Beam.deviceID,
            "auth_token": Beam.authToken,
        ])
    }

    // ── SSE ────────────────────────────────────────────────────────────────
    func startSSE() {
        _sseGeneration += 1
        _sseTask?.cancel()
        _sseRunning = true
        let gen = _sseGeneration
        _sseTask = Task { await _sseLoop(gen: gen) }
    }

    func stopSSE() {
        _sseRunning = false
        _sseGeneration += 1
        _sseTask?.cancel()
        _sseTask = nil
        _sseSession?.invalidateAndCancel()
        _sseSession = nil
    }

    private func _sseLoop(gen: Int) async {
        while _sseRunning && !Task.isCancelled && gen == _sseGeneration {
            do {
                let url = URL(string:
                    "\(Beam.server)/stream?device_id=\(Beam.deviceID)&channel_id=\(Beam.channelId)&auth_token=\(Beam.authToken)"
                )!
                var req = URLRequest(url: url)
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.timeoutInterval = 300
                let session = URLSession(configuration: .default)
                _sseSession = session
                let (bytes, _) = try await session.bytes(for: req)
                for try await line in bytes.lines {
                    guard _sseRunning && !Task.isCancelled && gen == _sseGeneration else { return }
                    if line.hasPrefix("data:") {
                        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if !raw.isEmpty,
                           let d = raw.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            await handleSSEMessage(json)
                        }
                    }
                }
            } catch {
                guard _sseRunning && !Task.isCancelled && gen == _sseGeneration else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func handleSSEMessage(_ json: [String: Any]) async {
        let msgType   = json["msg_type"]    as? String ?? "text"
        let content   = json["content"]     as? String ?? ""
        let msgID     = json["id"]          as? String ?? UUID().uuidString
        let fromDev   = json["from_device"] as? String ?? ""
        let chanId    = json["channel_id"]  as? String ?? ""
        let filename  = json["filename"]    as? String
        let createdAt = (json["created_at"] as? Double) ?? Date().timeIntervalSince1970

        if msgType == "text" {
            let msg = BeamMessage(id: msgID, from_device: fromDev, channel_id: chanId,
                                  msg_type: "text", content: content,
                                  filename: nil, created_at: createdAt)
            await MainActor.run {
                UIPasteboard.general.string = content
                InboxStore.shared.add(msg)
            }
        } else if msgType == "file" {
            let name = filename ?? "file"
            if content.hasPrefix("https://") {
                // GoFile URL — store URL directly, open in browser when tapped
                let msg = BeamMessage(id: msgID, from_device: fromDev, channel_id: chanId,
                                      msg_type: "file", content: content,
                                      filename: name, created_at: createdAt)
                await MainActor.run { InboxStore.shared.add(msg) }
            } else {
                // Legacy Beam file_id — download to local temp file
                let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
                let urlStr = "\(Beam.server)/download/\(content)?auth_token=\(Beam.authToken)&filename=\(enc)"
                guard let dlURL = URL(string: urlStr),
                      let (tmpURL, dlResp) = try? await URLSession.shared.download(from: dlURL),
                      (dlResp as? HTTPURLResponse)?.statusCode == 200 else { return }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.moveItem(at: tmpURL, to: dest)
                let msg = BeamMessage(id: msgID, from_device: fromDev, channel_id: chanId,
                                      msg_type: "file", content: dest.path,
                                      filename: name, created_at: createdAt)
                await MainActor.run { InboxStore.shared.add(msg) }
            }
        }
        try? await ack(messageID: msgID)
    }

    // ── Private ────────────────────────────────────────────────────────────
    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: URL(string: Beam.server + path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
