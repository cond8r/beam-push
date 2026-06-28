import Foundation

struct BeamMessage: Codable, Identifiable {
    var id:          String
    var from_device: String
    var channel_id:  String
    var msg_type:    String   // "text" | "file"
    var content:     String
    var filename:    String?
    var created_at:  Double
}
