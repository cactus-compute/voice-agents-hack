import Combine
import CoreBluetooth
import Foundation

/// Orchestrates the mesh: owns Peripheral + Central, routes inbound writes
/// through the dedup cache, and forwards to connected peers (excluding source)
/// while TTL > 1.
final class MeshManager: NSObject, ObservableObject {
    @Published private(set) var messages: [MeshMessage] = []
    @Published private(set) var connectedPeerCount: Int = 0
    @Published private(set) var sentCount: Int = 0
    @Published private(set) var receivedCount: Int = 0
    @Published private(set) var forwardedCount: Int = 0
    @Published private(set) var dedupedCount: Int = 0

    let selfId: UUID
    private var msgCounter: UInt32 = 0
    private let cache = MeshCache()
    private let peripheral = MeshPeripheral()
    private let central = MeshCentral()

    override init() {
        if let stored = UserDefaults.standard.string(forKey: "meshSelfId"),
           let uuid = UUID(uuidString: stored) {
            self.selfId = uuid
        } else {
            let newId = UUID()
            UserDefaults.standard.set(newId.uuidString, forKey: "meshSelfId")
            self.selfId = newId
        }
        super.init()
        peripheral.delegate = self
        central.delegate = self
    }

    func start() {
        peripheral.start()
        central.start()
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        msgCounter += 1
        let msg = MeshMessage(
            senderId: selfId,
            msgId: msgCounter,
            ttl: MeshConstants.defaultTTL,
            timestamp: MeshMessage.nowMs(),
            payload: trimmed
        )
        cache.insert(sender: msg.senderId, msgId: msg.msgId)
        messages.append(msg)
        sentCount += 1
        guard let data = msg.encode() else { return }
        central.broadcast(data, excluding: nil)
    }

    private func handleIncoming(_ data: Data, from sourceId: String?) {
        guard let msg = MeshMessage.decode(data) else { return }
        if msg.senderId == selfId { return }
        let isNew = cache.insert(sender: msg.senderId, msgId: msg.msgId)
        guard isNew else {
            dedupedCount += 1
            return
        }
        messages.append(msg)
        receivedCount += 1
        guard msg.ttl > 1 else { return }
        var forwarded = msg
        forwarded.ttl -= 1
        guard let fwData = forwarded.encode() else { return }
        central.broadcast(fwData, excluding: sourceId)
        forwardedCount += 1
    }
}

extension MeshManager: MeshPeripheralDelegate {
    func peripheral(didReceive data: Data, from centralId: String) {
        handleIncoming(data, from: centralId)
    }
}

extension MeshManager: MeshCentralDelegate {
    func central(connectedPeersChanged count: Int) {
        connectedPeerCount = count
    }
}
