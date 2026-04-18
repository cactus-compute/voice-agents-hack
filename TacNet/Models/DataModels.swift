import Foundation
import Combine
import CryptoKit

struct TreeNode: Codable, Equatable, Sendable {
    var id: String
    var label: String
    var claimedBy: String?
    var children: [TreeNode]

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case claimedBy = "claimed_by"
        case children
    }
}

struct NetworkConfig: Codable, Equatable, Sendable {
    var networkName: String
    var networkID: UUID
    var createdBy: String
    var pinHash: String?
    var version: Int
    var tree: TreeNode

    enum CodingKeys: String, CodingKey {
        case networkName = "network_name"
        case networkID = "network_id"
        case createdBy = "created_by"
        case pinHash = "pin_hash"
        case version
        case tree
    }

    var requiresPIN: Bool {
        pinHash != nil
    }

    var openSlotCount: Int {
        if tree.label.isEmpty, tree.claimedBy == nil, tree.children.isEmpty {
            return 0
        }
        return tree.openSlotCount
    }

    static func hashPIN(_ pin: String?) -> String? {
        guard let pin else {
            return nil
        }

        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func isValidPIN(_ pin: String?) -> Bool {
        if pinHash == nil {
            return true
        }
        return NetworkConfig.hashPIN(pin) == pinHash
    }

    mutating func applyMutation(_ mutateTree: (inout TreeNode) -> Void) {
        mutateTree(&tree)
        version += 1
    }

    @discardableResult
    mutating func mergeIfNewer(_ incoming: NetworkConfig) -> Bool {
        guard incoming.networkID == networkID else {
            return false
        }
        guard incoming.version > version else {
            return false
        }
        self = incoming
        return true
    }
}

extension TreeNode {
    var openSlotCount: Int {
        let selfOpen = claimedBy == nil ? 1 : 0
        let childOpen = children.reduce(0) { partial, child in
            partial + child.openSlotCount
        }
        return selfOpen + childOpen
    }
}

struct Message: Codable, Equatable, Sendable {
    enum MessageType: String, Codable, CaseIterable, Sendable {
        case broadcast = "BROADCAST"
        case compaction = "COMPACTION"
        case claim = "CLAIM"
        case release = "RELEASE"
        case treeUpdate = "TREE_UPDATE"
        case promote = "PROMOTE"
        case claimRejected = "CLAIM_REJECTED"

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let value = MessageType(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported message type: \(rawValue)"
                )
            }
            self = value
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    struct Payload: Codable, Equatable, Sendable {
        struct Location: Codable, Equatable, Sendable {
            var lat: Double
            var lon: Double
            var accuracy: Double
            var isFallback: Bool

            enum CodingKeys: String, CodingKey {
                case lat
                case lon
                case accuracy
                case isFallback = "is_fallback"
            }

            static func fromCoordinates(latitude: Double?, longitude: Double?, accuracy: Double?) -> Location {
                guard let latitude, let longitude, let accuracy else {
                    return Location(lat: 0, lon: 0, accuracy: -1, isFallback: true)
                }
                return Location(lat: latitude, lon: longitude, accuracy: accuracy, isFallback: false)
            }
        }

        var location: Location
        var encrypted: Bool
        var transcript: String?
        var summary: String?
        var claimedNodeID: String?
        var targetNodeID: String?
        var rejectionReason: String?
        var tree: TreeNode?
        var networkVersion: Int?

        enum CodingKeys: String, CodingKey {
            case location
            case encrypted
            case transcript
            case summary
            case claimedNodeID = "claimed_node_id"
            case targetNodeID = "target_node_id"
            case rejectionReason = "rejection_reason"
            case tree
            case networkVersion = "network_version"
        }
    }

    var id: UUID
    var type: MessageType
    var senderID: String
    var senderRole: String
    var parentID: String?
    var treeLevel: Int
    var timestamp: Date
    var ttl: Int
    var payload: Payload

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case senderID = "sender_id"
        case senderRole = "sender_role"
        case parentID = "parent_id"
        case treeLevel = "tree_level"
        case timestamp
        case ttl
        case payload
    }

    static func make(
        id: UUID = UUID(),
        type: MessageType,
        senderID: String,
        senderRole: String,
        parentID: String?,
        treeLevel: Int,
        ttl: Int,
        encrypted: Bool,
        latitude: Double?,
        longitude: Double?,
        accuracy: Double?,
        transcript: String? = nil,
        summary: String? = nil,
        claimedNodeID: String? = nil,
        targetNodeID: String? = nil,
        rejectionReason: String? = nil,
        tree: TreeNode? = nil,
        networkVersion: Int? = nil,
        timestamp: Date = Date()
    ) -> Message {
        Message(
            id: id,
            type: type,
            senderID: senderID,
            senderRole: senderRole,
            parentID: parentID,
            treeLevel: treeLevel,
            timestamp: timestamp,
            ttl: ttl,
            payload: Payload(
                location: .fromCoordinates(latitude: latitude, longitude: longitude, accuracy: accuracy),
                encrypted: encrypted,
                transcript: transcript,
                summary: summary,
                claimedNodeID: claimedNodeID,
                targetNodeID: targetNodeID,
                rejectionReason: rejectionReason,
                tree: tree,
                networkVersion: networkVersion
            )
        )
    }
}

struct NodeIdentity: Codable, Equatable, Sendable {
    var deviceID: String
    var claimedNodeID: String?
    var networkID: UUID

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case claimedNodeID = "claimed_node_id"
        case networkID = "network_id"
    }
}

struct NodeIdentityStore {
    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "TacNet.NodeIdentity") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func save(_ identity: NodeIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        defaults.set(data, forKey: storageKey)
    }

    func load() -> NodeIdentity? {
        guard let data = defaults.data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(NodeIdentity.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }
}

enum TreeHelpers {
    static func parent(of nodeID: String, in tree: TreeNode) -> TreeNode? {
        guard let path = path(to: nodeID, in: tree), path.count > 1 else {
            return nil
        }
        return path[path.count - 2]
    }

    static func siblings(of nodeID: String, in tree: TreeNode) -> [TreeNode] {
        guard let parentNode = parent(of: nodeID, in: tree) else {
            return []
        }
        return parentNode.children.filter { $0.id != nodeID }
    }

    static func children(of nodeID: String, in tree: TreeNode) -> [TreeNode] {
        findNode(withID: nodeID, in: tree)?.children ?? []
    }

    static func level(of nodeID: String, in tree: TreeNode) -> Int? {
        guard let path = path(to: nodeID, in: tree) else {
            return nil
        }
        return path.count - 1
    }

    private static func path(to nodeID: String, in tree: TreeNode) -> [TreeNode]? {
        if tree.id == nodeID {
            return [tree]
        }

        for child in tree.children {
            if let childPath = path(to: nodeID, in: child) {
                return [tree] + childPath
            }
        }

        return nil
    }

    private static func findNode(withID nodeID: String, in tree: TreeNode) -> TreeNode? {
        if tree.id == nodeID {
            return tree
        }

        for child in tree.children {
            if let found = findNode(withID: nodeID, in: child) {
                return found
            }
        }

        return nil
    }
}

final class MessageDeduplicator: @unchecked Sendable {
    private let capacity: Int
    private var seenSet: Set<UUID>
    private var ringBuffer: [UUID]
    private var nextEvictionIndex: Int
    private let lock = NSLock()

    init(capacity: Int = 50_000) {
        self.capacity = max(1, capacity)
        self.seenSet = Set(minimumCapacity: self.capacity)
        self.ringBuffer = []
        self.ringBuffer.reserveCapacity(self.capacity)
        self.nextEvictionIndex = 0
    }

    func isDuplicate(messageId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if seenSet.contains(messageId) {
            return true
        }

        if ringBuffer.count < capacity {
            ringBuffer.append(messageId)
        } else {
            let evicted = ringBuffer[nextEvictionIndex]
            seenSet.remove(evicted)
            ringBuffer[nextEvictionIndex] = messageId
            nextEvictionIndex = (nextEvictionIndex + 1) % capacity
        }

        seenSet.insert(messageId)
        return false
    }

    var trackedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return seenSet.count
    }
}

final class TreeBuilderViewModel: ObservableObject, @unchecked Sendable {
    @Published private(set) var networkConfig: NetworkConfig
    @Published private(set) var versionHistory: [Int]

    private let lock = NSLock()

    init(
        networkName: String = "New TacNet Network",
        createdBy: String = "organiser-device",
        pin: String? = nil,
        rootNode: TreeNode = TreeNode(id: "root", label: "Commander", claimedBy: nil, children: []),
        initialVersion: Int = 1,
        networkID: UUID = UUID()
    ) {
        let normalizedName = Self.normalizedNetworkName(networkName)
        let pinHash = Self.pinHash(from: pin)
        let initialConfig = NetworkConfig(
            networkName: normalizedName,
            networkID: networkID,
            createdBy: createdBy,
            pinHash: pinHash,
            version: max(1, initialVersion),
            tree: rootNode
        )

        networkConfig = initialConfig
        versionHistory = [initialConfig.version]
    }

    var currentVersion: Int {
        withLock { networkConfig.version }
    }

    var isTreeEmpty: Bool {
        withLock {
            let tree = networkConfig.tree
            return tree.children.isEmpty && tree.claimedBy == nil && tree.label.isEmpty
        }
    }

    func node(withID nodeID: String) -> TreeNode? {
        withLock {
            Self.findNode(withID: nodeID, in: networkConfig.tree)
        }
    }

    @discardableResult
    func addNode(parentID: String?, label: String) -> TreeNode? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            return nil
        }

        return withLock {
            var updatedConfig = networkConfig
            let targetParentID = parentID ?? updatedConfig.tree.id

            guard let createdNode = Self.insertChild(
                parentID: targetParentID,
                label: trimmedLabel,
                in: &updatedConfig.tree
            ) else {
                return nil
            }

            commitMutation(updatedConfig)
            return createdNode
        }
    }

    @discardableResult
    func removeNode(nodeID: String) -> Bool {
        withLock {
            var updatedConfig = networkConfig
            let didRemove: Bool

            if updatedConfig.tree.id == nodeID {
                didRemove = true
                updatedConfig.tree.claimedBy = nil
                updatedConfig.tree.label = ""
                updatedConfig.tree.children = []
            } else {
                didRemove = Self.removeNode(nodeID: nodeID, from: &updatedConfig.tree)
            }

            guard didRemove else {
                return false
            }

            commitMutation(updatedConfig)
            return true
        }
    }

    @discardableResult
    func renameNode(nodeID: String, newLabel: String) -> Bool {
        withLock {
            var updatedConfig = networkConfig
            guard Self.renameNode(nodeID: nodeID, newLabel: newLabel, in: &updatedConfig.tree) else {
                return false
            }
            commitMutation(updatedConfig)
            return true
        }
    }

    @discardableResult
    func updateNetworkName(_ networkName: String) -> Bool {
        withLock {
            let normalized = Self.normalizedNetworkName(networkName)
            guard normalized != networkConfig.networkName else {
                return false
            }

            var updatedConfig = networkConfig
            updatedConfig.networkName = normalized
            commitMutation(updatedConfig)
            return true
        }
    }

    @discardableResult
    func updatePin(_ pin: String?) -> Bool {
        withLock {
            let updatedHash = Self.pinHash(from: pin)
            guard updatedHash != networkConfig.pinHash else {
                return false
            }

            var updatedConfig = networkConfig
            updatedConfig.pinHash = updatedHash
            commitMutation(updatedConfig)
            return true
        }
    }

    @discardableResult
    func clearTree() -> Bool {
        withLock {
            let tree = networkConfig.tree
            guard !(tree.children.isEmpty && tree.claimedBy == nil && tree.label.isEmpty) else {
                return false
            }

            var updatedConfig = networkConfig
            updatedConfig.tree.claimedBy = nil
            updatedConfig.tree.label = ""
            updatedConfig.tree.children = []
            commitMutation(updatedConfig)
            return true
        }
    }

    func serializedTreeData(prettyPrinted: Bool = false) -> Data? {
        withLock {
            let encoder = Self.jsonEncoder(prettyPrinted: prettyPrinted)
            return try? encoder.encode(networkConfig.tree)
        }
    }

    func serializedTreeJSON(prettyPrinted: Bool = false) -> String? {
        guard let data = serializedTreeData(prettyPrinted: prettyPrinted) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func serializedNetworkConfigData(prettyPrinted: Bool = false) -> Data? {
        withLock {
            let encoder = Self.jsonEncoder(prettyPrinted: prettyPrinted)
            return try? encoder.encode(networkConfig)
        }
    }

    func serializedNetworkConfigJSON(prettyPrinted: Bool = false) -> String? {
        guard let data = serializedNetworkConfigData(prettyPrinted: prettyPrinted) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func commitMutation(_ updatedConfig: NetworkConfig) {
        var next = updatedConfig
        next.version += 1
        networkConfig = next
        versionHistory.append(next.version)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func normalizedNetworkName(_ networkName: String) -> String {
        let trimmed = networkName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Network" : trimmed
    }

    private static func pinHash(from pin: String?) -> String? {
        NetworkConfig.hashPIN(pin)
    }

    private static func jsonEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted {
            formatting.insert(.prettyPrinted)
        }
        encoder.outputFormatting = formatting
        return encoder
    }

    private static func findNode(withID nodeID: String, in tree: TreeNode) -> TreeNode? {
        if tree.id == nodeID {
            return tree
        }

        for child in tree.children {
            if let found = findNode(withID: nodeID, in: child) {
                return found
            }
        }

        return nil
    }

    private static func insertChild(parentID: String, label: String, in tree: inout TreeNode) -> TreeNode? {
        if tree.id == parentID {
            let node = TreeNode(
                id: UUID().uuidString,
                label: label,
                claimedBy: nil,
                children: []
            )
            tree.children.append(node)
            return node
        }

        for index in tree.children.indices {
            if let created = insertChild(parentID: parentID, label: label, in: &tree.children[index]) {
                return created
            }
        }

        return nil
    }

    private static func removeNode(nodeID: String, from tree: inout TreeNode) -> Bool {
        if let directChildIndex = tree.children.firstIndex(where: { $0.id == nodeID }) {
            tree.children.remove(at: directChildIndex)
            return true
        }

        for index in tree.children.indices {
            if removeNode(nodeID: nodeID, from: &tree.children[index]) {
                return true
            }
        }

        return false
    }

    private static func renameNode(nodeID: String, newLabel: String, in tree: inout TreeNode) -> Bool {
        if tree.id == nodeID {
            tree.label = newLabel
            return true
        }

        for index in tree.children.indices {
            if renameNode(nodeID: nodeID, newLabel: newLabel, in: &tree.children[index]) {
                return true
            }
        }

        return false
    }
}
