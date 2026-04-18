import Foundation

struct MeshMessage: Codable, Identifiable, Equatable {
    let senderId: UUID
    let msgId: UInt32
    var ttl: UInt8
    let timestamp: Int64
    let payload: String

    var id: String { "\(senderId.uuidString):\(msgId)" }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> MeshMessage? {
        try? JSONDecoder().decode(MeshMessage.self, from: data)
    }
}
