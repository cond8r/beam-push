import Foundation

class InboxStore: ObservableObject {
    static let shared = InboxStore()
    @Published var messages: [BeamMessage] = []

    private let key = "beam_inbox_v1"
    private let maxMessages = 200

    init() {
        load()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([BeamMessage].self, from: data) else { return }
        messages = saved
    }

    private func save() {
        let trimmed = Array(messages.prefix(maxMessages))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func add(_ msg: BeamMessage) {
        DispatchQueue.main.async {
            guard !self.messages.contains(where: { $0.id == msg.id }) else { return }
            self.messages.insert(msg, at: 0)
            if self.messages.count > self.maxMessages { self.messages.removeLast() }
            self.save()
        }
    }

    func clear() {
        messages.removeAll()
        save()
    }
}
