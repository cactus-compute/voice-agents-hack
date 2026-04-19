import XCTest
import SwiftUI
@testable import TacNet

final class TacNetTests: XCTestCase {
    func testCactusFunctionsAreCallableViaSwiftBindings() {
        XCTAssertTrue(CactusFunctionProbe.verifyCallableSymbols())
    }

    func testFrameworkImportsProbeCompiles() {
        FrameworkImportsProbe.touchFrameworkSymbols()
        XCTAssertTrue(true)
    }

    func testTreeNodeRoundTripEncodingWithNestedChildren() throws {
        let original = TreeNode(
            id: "root",
            label: "Root",
            claimedBy: "commander",
            children: [
                TreeNode(
                    id: "alpha",
                    label: "Alpha",
                    claimedBy: nil,
                    children: [
                        TreeNode(
                            id: "alpha-1",
                            label: "Alpha 1",
                            claimedBy: "device-a1",
                            children: []
                        )
                    ]
                ),
                TreeNode(
                    id: "bravo",
                    label: "Bravo",
                    claimedBy: "device-b",
                    children: []
                )
            ]
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TreeNode.self, from: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testTreeNodeDecodingRejectsMalformedJSON() {
        let malformedPayloads = [
            #"{"label":"Root","claimed_by":null,"children":[]}"#, // missing id
            #"{"id":"root","label":"Root","claimed_by":null,"children":"invalid"}"#, // children wrong type
            #"{}"#, // empty object
            #"[]"#  // array instead of object
        ]

        for json in malformedPayloads {
            let data = Data(json.utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(TreeNode.self, from: data)) { error in
                XCTAssertTrue(error is DecodingError, "Expected DecodingError, got \(type(of: error))")
            }
        }
    }

    func testNetworkConfigVersionMonotonicityAndStaleDiscard() {
        let networkID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var local = NetworkConfig(
            networkName: "TacNet Alpha",
            networkID: networkID,
            createdBy: "organizer-device",
            pinHash: "pinhash",
            version: 1,
            tree: TreeNode(id: "root", label: "Root", claimedBy: nil, children: [])
        )

        local.applyMutation { tree in
            tree.label = "Root Updated"
        }
        XCTAssertEqual(local.version, 2, "Tree mutation must increment version exactly by 1")

        let stale = NetworkConfig(
            networkName: "TacNet Alpha",
            networkID: networkID,
            createdBy: "organizer-device",
            pinHash: "pinhash",
            version: 2,
            tree: TreeNode(id: "root", label: "STALE", claimedBy: nil, children: [])
        )
        XCTAssertFalse(local.mergeIfNewer(stale), "Stale versions (<= local) must be discarded")
        XCTAssertEqual(local.tree.label, "Root Updated")

        let jumped = NetworkConfig(
            networkName: "TacNet Alpha",
            networkID: networkID,
            createdBy: "organizer-device",
            pinHash: "pinhash",
            version: 5,
            tree: TreeNode(id: "root", label: "Fresh", claimedBy: nil, children: [])
        )
        XCTAssertTrue(local.mergeIfNewer(jumped), "Higher versions must be accepted even if > local + 1")
        XCTAssertEqual(local.version, 5)
        XCTAssertEqual(local.tree.label, "Fresh")
    }

    func testMessageEnvelopeSerializationHasAllRequiredFields() throws {
        let message = Message.make(
            type: .broadcast,
            senderID: "device-alpha",
            senderRole: "leaf",
            parentID: "parent-1",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: 37.3318,
            longitude: -122.0312,
            accuracy: 5.0,
            transcript: "CONTACT front",
            summary: nil,
            claimedNodeID: nil,
            targetNodeID: nil,
            rejectionReason: nil,
            tree: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoded = try JSONEncoder().encode(message)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        let id = try XCTUnwrap(json["id"] as? String)
        XCTAssertNotNil(UUID(uuidString: id), "id should encode as UUID string")

        XCTAssertTrue(json["type"] is String, "type should serialize as a string")
        XCTAssertTrue(json["sender_id"] is String)
        XCTAssertTrue(json["sender_role"] is String)
        XCTAssertTrue(json["parent_id"] is String)
        XCTAssertTrue(json["tree_level"] is NSNumber)
        XCTAssertTrue(json["timestamp"] is NSNumber || json["timestamp"] is String)
        XCTAssertTrue(json["ttl"] is NSNumber)

        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertTrue(payload["encrypted"] is Bool || payload["encrypted"] is NSNumber)
        XCTAssertTrue(payload["transcript"] is String)
        XCTAssertTrue(payload["location"] is [String: Any], "location must be present in payload")
    }

    func testMessageTypeEnumCoverageAndUnknownTypeRejection() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        try Message.MessageType.allCases.forEach { messageType in
            let original = Message.make(
                type: messageType,
                senderID: "device-1",
                senderRole: "participant",
                parentID: "root",
                treeLevel: 1,
                ttl: 3,
                encrypted: true,
                latitude: 1.0,
                longitude: 2.0,
                accuracy: 3.0,
                transcript: "sample",
                summary: "sample-summary",
                claimedNodeID: "node-1",
                targetNodeID: "node-2",
                rejectionReason: "organiser_wins",
                tree: TreeNode(id: "root", label: "Root", claimedBy: nil, children: []),
                timestamp: Date(timeIntervalSince1970: 1_700_000_001)
            )

            let roundTripped = try decoder.decode(Message.self, from: encoder.encode(original))
            XCTAssertEqual(roundTripped.type, messageType)
        }

        let unknownTypeJSON = """
        {
          "id":"11111111-2222-3333-4444-555555555555",
          "type":"UNKNOWN_TYPE",
          "sender_id":"device-1",
          "sender_role":"participant",
          "parent_id":"root",
          "tree_level":1,
          "timestamp":1700000001,
          "ttl":3,
          "payload":{
            "location":{"lat":0,"lon":0,"accuracy":-1,"is_fallback":true},
            "encrypted":false
          }
        }
        """

        XCTAssertThrowsError(try decoder.decode(Message.self, from: Data(unknownTypeJSON.utf8))) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testNodeIdentityPersistsAcrossSimulatedRestartAndCanBeCleared() throws {
        let suiteName = "TacNetTests.NodeIdentity.\(UUID().uuidString)"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaultsA.removePersistentDomain(forName: suiteName)
        defer { defaultsA.removePersistentDomain(forName: suiteName) }

        let storeA = NodeIdentityStore(defaults: defaultsA)
        let identity = NodeIdentity(
            deviceID: "device-xyz",
            claimedNodeID: "node-007",
            networkID: UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!
        )

        XCTAssertNoThrow(try storeA.save(identity))

        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let storeB = NodeIdentityStore(defaults: defaultsB)
        XCTAssertEqual(storeB.load(), identity, "Identity should survive simulated relaunch")

        storeB.clear()
        XCTAssertNil(storeA.load(), "Cleared identity should be nil on next read")
    }

    func testGPSCoordinateEmbeddingUsesLiveValuesAndFallbackWhenUnavailable() throws {
        let withLocation = Message.make(
            type: .broadcast,
            senderID: "device-live",
            senderRole: "leaf",
            parentID: "parent-2",
            treeLevel: 2,
            ttl: 5,
            encrypted: false,
            latitude: 34.0522,
            longitude: -118.2437,
            accuracy: 4.5,
            transcript: "Movement east",
            summary: nil,
            claimedNodeID: nil,
            targetNodeID: nil,
            rejectionReason: nil,
            tree: nil
        )

        XCTAssertEqual(withLocation.payload.location.lat, 34.0522, accuracy: 0.000001)
        XCTAssertEqual(withLocation.payload.location.lon, -118.2437, accuracy: 0.000001)
        XCTAssertEqual(withLocation.payload.location.accuracy, 4.5, accuracy: 0.000001)
        XCTAssertFalse(withLocation.payload.location.isFallback)

        let withoutLocation = Message.make(
            type: .broadcast,
            senderID: "device-fallback",
            senderRole: "leaf",
            parentID: "parent-2",
            treeLevel: 2,
            ttl: 5,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Fallback position",
            summary: nil,
            claimedNodeID: nil,
            targetNodeID: nil,
            rejectionReason: nil,
            tree: nil
        )

        XCTAssertTrue(withoutLocation.payload.location.isFallback, "Fallback GPS should be flagged")

        let encoded = try JSONEncoder().encode(withoutLocation)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertNotNil(payload["location"], "location field must be present even without live GPS")
    }

    func testMessageRouterBroadcastRoutingSiblingReceives() {
        let tree = makeFixtureTree()
        let router = MessageRouter()
        let message = Message.make(
            type: .broadcast,
            senderID: "alpha-1",
            senderRole: "participant",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Contact east"
        )

        XCTAssertTrue(router.shouldDisplay(message, for: "alpha-2", in: tree))
    }

    func testMessageRouterBroadcastRoutingParentReceives() {
        let tree = makeFixtureTree()
        let router = MessageRouter()
        let message = Message.make(
            type: .broadcast,
            senderID: "alpha-1",
            senderRole: "participant",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Contact east"
        )

        XCTAssertTrue(router.shouldDisplay(message, for: "alpha", in: tree))
    }

    func testMessageRouterBroadcastRoutingGrandparentExcluded() {
        let tree = makeFixtureTree()
        let router = MessageRouter()
        let message = Message.make(
            type: .broadcast,
            senderID: "alpha-1",
            senderRole: "participant",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Contact east"
        )

        XCTAssertFalse(router.shouldDisplay(message, for: "root", in: tree))
    }

    func testMessageRouterBroadcastRoutingCousinExcluded() {
        let tree = makeFixtureTree()
        let router = MessageRouter()
        let message = Message.make(
            type: .broadcast,
            senderID: "alpha-1",
            senderRole: "participant",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Contact east"
        )

        XCTAssertFalse(router.shouldDisplay(message, for: "charlie-1", in: tree))
    }

    func testMessageRouterCompactionRoutingOnlyParentReceives() {
        let tree = makeFixtureTree()
        let router = MessageRouter()
        let message = Message.make(
            type: .compaction,
            senderID: "alpha",
            senderRole: "participant",
            parentID: "root",
            treeLevel: 1,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            summary: "Alpha reports contact east"
        )

        XCTAssertTrue(router.shouldDisplay(message, for: "root", in: tree))
        XCTAssertFalse(router.shouldDisplay(message, for: "bravo", in: tree))
        XCTAssertFalse(router.shouldDisplay(message, for: "charlie", in: tree))
    }

    func testMessageRouterConstructsOutgoingEnvelopeWithRequiredFieldsAndGPS() throws {
        let tree = makeFixtureTree()
        let router = MessageRouter(
            defaultTTL: 0,
            gpsProvider: {
                MessageRouter.GPSReading(latitude: 47.6205, longitude: -122.3493, accuracy: 3.2)
            }
        )

        let outgoing = router.makeBroadcastMessage(
            transcript: "Contact east",
            senderID: "device-alpha-1",
            senderNodeID: "alpha-1",
            senderRole: "leaf",
            in: tree
        )

        XCTAssertEqual(outgoing.type, .broadcast)
        XCTAssertEqual(outgoing.senderID, "device-alpha-1")
        XCTAssertEqual(outgoing.senderRole, "leaf")
        XCTAssertEqual(outgoing.parentID, "alpha")
        XCTAssertEqual(outgoing.treeLevel, 2)
        XCTAssertGreaterThan(outgoing.ttl, 0, "Outgoing envelope must always have ttl > 0")
        XCTAssertEqual(outgoing.payload.transcript, "Contact east")
        XCTAssertNil(outgoing.payload.summary)
        XCTAssertEqual(outgoing.payload.location.lat, 47.6205, accuracy: 0.000001)
        XCTAssertEqual(outgoing.payload.location.lon, -122.3493, accuracy: 0.000001)
        XCTAssertEqual(outgoing.payload.location.accuracy, 3.2, accuracy: 0.000001)
        XCTAssertFalse(outgoing.payload.location.isFallback)

        let encoded = try JSONEncoder().encode(outgoing)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let idString = try XCTUnwrap(json["id"] as? String)
        XCTAssertNotNil(UUID(uuidString: idString), "Outgoing id must be a valid UUID string")
        XCTAssertNotNil(json["timestamp"], "Outgoing envelope must include a timestamp")
        XCTAssertGreaterThan((json["ttl"] as? NSNumber)?.intValue ?? 0, 0)

        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        let location = try XCTUnwrap(payload["location"] as? [String: Any])
        XCTAssertTrue(location["lat"] is NSNumber)
        XCTAssertTrue(location["lon"] is NSNumber)
        XCTAssertTrue(location["accuracy"] is NSNumber)
    }

    func testTreeHelpersParentLookupForRootLeafIntermediateAndMissing() {
        let tree = makeFixtureTree()

        XCTAssertEqual(TreeHelpers.parent(of: "alpha", in: tree)?.id, "root")
        XCTAssertEqual(TreeHelpers.parent(of: "alpha-1", in: tree)?.id, "alpha")
        XCTAssertNil(TreeHelpers.parent(of: "root", in: tree))
        XCTAssertNil(TreeHelpers.parent(of: "missing", in: tree))
    }

    func testTreeHelpersSiblingsLookupExcludesSelfAndHandlesRootSingleChildAndMissing() {
        let tree = makeFixtureTree()

        XCTAssertEqual(TreeHelpers.siblings(of: "alpha-1", in: tree).map(\.id), ["alpha-2"])
        XCTAssertEqual(TreeHelpers.siblings(of: "alpha", in: tree).map(\.id), ["bravo", "charlie"])
        XCTAssertEqual(TreeHelpers.siblings(of: "charlie-1", in: tree).count, 0, "Single child should have no siblings")
        XCTAssertEqual(TreeHelpers.siblings(of: "root", in: tree).count, 0, "Root should have no siblings")
        XCTAssertEqual(TreeHelpers.siblings(of: "missing", in: tree).count, 0, "Missing node should produce no siblings")
    }

    func testTreeHelpersChildrenLookupForRootIntermediateLeafAndMissing() {
        let tree = makeFixtureTree()

        XCTAssertEqual(TreeHelpers.children(of: "root", in: tree).map(\.id), ["alpha", "bravo", "charlie"])
        XCTAssertEqual(TreeHelpers.children(of: "alpha", in: tree).map(\.id), ["alpha-1", "alpha-2"])
        XCTAssertEqual(TreeHelpers.children(of: "bravo", in: tree).count, 0, "Leaf should have no children")
        XCTAssertEqual(TreeHelpers.children(of: "missing", in: tree).count, 0, "Missing node should produce no children")
    }

    func testTreeHelpersLevelLookupForRootIntermediateLeafAndMissing() {
        let tree = makeFixtureTree()

        XCTAssertEqual(TreeHelpers.level(of: "root", in: tree), 0)
        XCTAssertEqual(TreeHelpers.level(of: "alpha", in: tree), 1)
        XCTAssertEqual(TreeHelpers.level(of: "alpha-1", in: tree), 2)
        XCTAssertNil(TreeHelpers.level(of: "missing", in: tree))
    }

    func testMessageDeduplicatorReturnsFalseForFirstSeenAndTrueForReseen() {
        let deduplicator = MessageDeduplicator(capacity: 50_000)
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        XCTAssertFalse(deduplicator.isDuplicate(messageId: id))
        XCTAssertTrue(deduplicator.isDuplicate(messageId: id))
    }

    func testMessageDeduplicatorDifferentUUIDsAreNotDuplicates() {
        let deduplicator = MessageDeduplicator(capacity: 50_000)
        let idA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let idB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        XCTAssertFalse(deduplicator.isDuplicate(messageId: idA))
        XCTAssertFalse(deduplicator.isDuplicate(messageId: idB))
    }

    func testMessageDeduplicatorStress10kEntriesMaintainsCorrectness() {
        let deduplicator = MessageDeduplicator(capacity: 50_000)
        let ids = (0..<10_000).map(deterministicUUID(from:))

        ids.forEach { id in
            XCTAssertFalse(deduplicator.isDuplicate(messageId: id), "First-seen UUID must not be duplicate")
        }

        ids.forEach { id in
            XCTAssertTrue(deduplicator.isDuplicate(messageId: id), "Re-seen UUID must be duplicate")
        }
    }

    func testMessageDeduplicatorBoundedGrowthAndRecentEntriesRemainTracked() {
        let capacity = 1_000
        let deduplicator = MessageDeduplicator(capacity: capacity)
        let ids = (0..<(capacity * 2)).map(deterministicUUID(from:))

        ids.forEach { id in
            XCTAssertFalse(deduplicator.isDuplicate(messageId: id))
        }

        XCTAssertEqual(deduplicator.trackedCount, capacity, "Seen-set size should remain bounded by capacity")

        ids.suffix(1_000).forEach { id in
            XCTAssertTrue(deduplicator.isDuplicate(messageId: id), "Most-recent IDs should still be tracked")
        }

        XCTAssertFalse(deduplicator.isDuplicate(messageId: ids[0]), "Oldest entries should be evicted after overflow")
    }

    func testBluetoothMeshUUIDDefinitionsMatchExpectedValues() {
        XCTAssertEqual(BluetoothMeshUUIDs.service.uuidString.uppercased(), "7B4D8C10-3A8E-4D1A-9F53-2E28D9C1A001")
        XCTAssertEqual(BluetoothMeshUUIDs.broadcastCharacteristic.uuidString.uppercased(), "7B4D8C10-3A8E-4D1A-9F53-2E28D9C1A101")
        XCTAssertEqual(BluetoothMeshUUIDs.compactionCharacteristic.uuidString.uppercased(), "7B4D8C10-3A8E-4D1A-9F53-2E28D9C1A102")
        XCTAssertEqual(BluetoothMeshUUIDs.treeConfigCharacteristic.uuidString.uppercased(), "7B4D8C10-3A8E-4D1A-9F53-2E28D9C1A103")
    }

    func testBluetoothMeshServiceFloodsLocalMessagesToAllConnectedPeers() throws {
        let transport = MockBluetoothMeshTransport()
        let service = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))

        let peerA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let peerB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        transport.emit(.connectionStateChanged(peerA, .connected))
        transport.emit(.connectionStateChanged(peerB, .connected))

        let message = makeMeshMessage(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            ttl: 3
        )
        service.publish(message)

        XCTAssertEqual(transport.sentPackets.count, 1)
        let sent = try XCTUnwrap(transport.sentPackets.first)
        XCTAssertEqual(sent.peerIDs, Set([peerA, peerB]))

        let forwarded = try decodeMessage(from: sent.data)
        XCTAssertEqual(forwarded.id, message.id)
        XCTAssertEqual(forwarded.ttl, 3, "Locally-originated message should keep original TTL on first flood")
    }

    func testBluetoothMeshServiceDecrementsTTLOnReceiveAndRelaysToOtherPeers() throws {
        let transport = MockBluetoothMeshTransport()
        let service = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))

        let sourcePeer = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let relayPeer1 = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let relayPeer2 = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        transport.emit(.connectionStateChanged(sourcePeer, .connected))
        transport.emit(.connectionStateChanged(relayPeer1, .connected))
        transport.emit(.connectionStateChanged(relayPeer2, .connected))

        var receivedLocally: [Message] = []
        service.onMessageReceived = { receivedLocally.append($0) }

        let inbound = makeMeshMessage(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            ttl: 2
        )
        let inboundData = try JSONEncoder().encode(inbound)
        transport.emit(.receivedData(inboundData, from: sourcePeer))

        XCTAssertEqual(receivedLocally.count, 1)
        XCTAssertEqual(receivedLocally[0].ttl, 1, "TTL must decrement by one hop on receipt")

        XCTAssertEqual(transport.sentPackets.count, 1)
        let relayPacket = try XCTUnwrap(transport.sentPackets.first)
        XCTAssertEqual(relayPacket.peerIDs, Set([relayPeer1, relayPeer2]), "Relay should exclude the source peer")

        let relayed = try decodeMessage(from: relayPacket.data)
        XCTAssertEqual(relayed.ttl, 1)
    }

    func testBluetoothMeshServiceProcessesTTL1LocallyAndDoesNotRelay() throws {
        let transport = MockBluetoothMeshTransport()
        let service = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))

        let sourcePeer = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherPeer = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        transport.emit(.connectionStateChanged(sourcePeer, .connected))
        transport.emit(.connectionStateChanged(otherPeer, .connected))

        var receivedLocally: [Message] = []
        service.onMessageReceived = { receivedLocally.append($0) }

        let inbound = makeMeshMessage(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            ttl: 1
        )
        let inboundData = try JSONEncoder().encode(inbound)
        transport.emit(.receivedData(inboundData, from: sourcePeer))

        XCTAssertEqual(receivedLocally.count, 1)
        XCTAssertEqual(receivedLocally[0].ttl, 0, "TTL=1 should become TTL=0 after processing this hop")
        XCTAssertEqual(transport.sentPackets.count, 0, "TTL reaching 0 must not be re-broadcast")
    }

    func testBluetoothMeshServiceDropsDuplicateInboundMessages() throws {
        let transport = MockBluetoothMeshTransport()
        let service = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))

        let sourcePeer = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let relayPeer = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        transport.emit(.connectionStateChanged(sourcePeer, .connected))
        transport.emit(.connectionStateChanged(relayPeer, .connected))

        var receivedLocally: [Message] = []
        service.onMessageReceived = { receivedLocally.append($0) }

        let messageID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let inbound = makeMeshMessage(id: messageID, ttl: 3)
        let inboundData = try JSONEncoder().encode(inbound)

        transport.emit(.receivedData(inboundData, from: sourcePeer))
        transport.emit(.receivedData(inboundData, from: relayPeer))

        XCTAssertEqual(receivedLocally.count, 1, "Duplicate UUID should be ignored")
        XCTAssertEqual(transport.sentPackets.count, 1, "Duplicate UUID should not be re-broadcast")
    }

    func testBluetoothMeshServiceStoreAndForwardFlushesOnConnect() {
        let transport = MockBluetoothMeshTransport()
        let service = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))

        let pending = makeMeshMessage(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            ttl: 3
        )
        service.publish(pending)

        XCTAssertEqual(transport.sentPackets.count, 0, "Message should be queued when there are no connected peers")
        XCTAssertEqual(service.pendingRelayCount, 1)

        let peer = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        transport.emit(.connectionStateChanged(peer, .connected))

        XCTAssertEqual(transport.sentPackets.count, 1, "Queued messages should flush when a peer connects")
        XCTAssertEqual(transport.sentPackets[0].peerIDs, Set([peer]))
        XCTAssertEqual(service.pendingRelayCount, 0)
    }

    func testBluetoothMeshServiceTracksPeerConnectionStateTransitions() {
        let transport = MockBluetoothMeshTransport()
        let service = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))

        let peer = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        XCTAssertEqual(service.connectionState(for: peer), .disconnected)
        XCTAssertTrue(service.connectedPeerIDs.isEmpty)

        transport.emit(.connectionStateChanged(peer, .connected))
        XCTAssertEqual(service.connectionState(for: peer), .connected)
        XCTAssertEqual(service.connectedPeerIDs, Set([peer]))

        transport.emit(.connectionStateChanged(peer, .disconnected))
        XCTAssertEqual(service.connectionState(for: peer), .disconnected)
        XCTAssertTrue(service.connectedPeerIDs.isEmpty)
    }

    func testModelDownloadServiceReportsMonotonicProgressWithAtLeastFiveIntermediateCallbacksAndUnlocksGate() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let mockSession = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(50, 1_000), (200, 1_000), (700, 1_000), (1_000, 1_000)],
                    result: .success(temporaryModelFile)
                )
            ]
        )

        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 20_000_000_000
        )

        let gateLockedBeforeDownload = await service.canUseTacticalFeatures()
        XCTAssertFalse(gateLockedBeforeDownload, "App should stay gated before model download completes")

        let progressCollector = LockedArray<Double>()
        _ = try await service.ensureModelAvailable { progress in
            progressCollector.append(progress)
        }
        let reportedProgress = progressCollector.values

        let gateUnlockedAfterDownload = await service.canUseTacticalFeatures()
        XCTAssertTrue(gateUnlockedAfterDownload, "Gate should unlock once model download completes")
        XCTAssertTrue(reportedProgress.allSatisfy { $0 >= 0 && $0 <= 1 }, "Progress must stay inside [0, 1]")
        XCTAssertTrue(
            zip(reportedProgress, reportedProgress.dropFirst()).allSatisfy { lhs, rhs in lhs <= rhs + 0.000_000_1 },
            "Progress callbacks must be monotonic"
        )
        let finalProgress = try XCTUnwrap(reportedProgress.last)
        XCTAssertEqual(finalProgress, 1.0, accuracy: 0.000_001)

        let intermediateCallbacks = reportedProgress.filter { $0 > 0 && $0 < 1 }
        XCTAssertGreaterThanOrEqual(intermediateCallbacks.count, 5, "Need at least 5 intermediate progress callbacks")

        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertNil(mockSession.request(at: 0)?.resumeData, "Initial attempt should start without resume data")
    }

    func testModelDownloadServiceFailsBeforeNetworkWhenStorageIsInsufficient() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let mockSession = MockURLSessionDownloadClient(scriptedResponses: [])
        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 1_000_000_000
        )

        do {
            _ = try await service.ensureModelAvailable()
            XCTFail("Expected insufficient storage error")
        } catch let error as ModelDownloadServiceError {
            guard case let .insufficientStorage(requiredBytes, availableBytes) = error else {
                return XCTFail("Expected insufficientStorage, got \(error)")
            }
            XCTAssertEqual(requiredBytes, makeModelDownloadConfiguration().expectedModelSizeBytes)
            XCTAssertEqual(availableBytes, 1_000_000_000)
        }

        XCTAssertEqual(mockSession.requestCount, 0, "Network must not start when storage check fails")
        let gateState = await service.canUseTacticalFeatures()
        XCTAssertFalse(gateState)
        let modelDirectory = sandbox.appSupportDirectory
            .appendingPathComponent(makeModelDownloadConfiguration().modelDirectoryName, isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: modelDirectory.path),
            "Storage precheck failure should not leave partial model files or folders"
        )
    }

    func testModelDownloadServiceResumesUsingStoredResumeDataAfterInterruption() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let resumeData = Data("resume-point".utf8)
        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let mockSession = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(250, 1_000)],
                    result: .failure(URLSessionDownloadClientError.interrupted(resumeData: resumeData))
                ),
                .init(
                    progressEvents: [(900, 1_000), (1_000, 1_000)],
                    result: .success(temporaryModelFile)
                )
            ]
        )

        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 20_000_000_000
        )

        do {
            _ = try await service.ensureModelAvailable()
            XCTFail("Expected first attempt to be interrupted")
        } catch let error as ModelDownloadServiceError {
            guard case let .interrupted(canResume) = error else {
                return XCTFail("Expected interrupted error, got \(error)")
            }
            XCTAssertTrue(canResume, "Interrupted errors should indicate resumable state when resumeData exists")
        }

        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertNil(mockSession.request(at: 0)?.resumeData)

        _ = try await service.ensureModelAvailable()

        XCTAssertEqual(mockSession.requestCount, 2)
        XCTAssertEqual(mockSession.request(at: 1)?.resumeData, resumeData, "Second attempt should use stored resume data")
        let gateState = await service.canUseTacticalFeatures()
        XCTAssertTrue(gateState)
    }

    func testEnsureModelAvailableRejectsNonZipPayloadInProductionMode() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        // 19 bytes of non-zip content ("Access denied\n") mimic a real HTTP
        // error body that a naïve implementation would happily promote to the
        // sentinel path — leading to Cactus crashing at load time. In
        // production mode (requiresZipArchive == true) the service MUST
        // reject this payload.
        let accessDeniedURL = sandbox.baseDirectory
            .appendingPathComponent("access-denied-\(UUID().uuidString).bin")
        let errorBody = Data("Access denied 123!\n".utf8)
        XCTAssertEqual(errorBody.count, 19, "Test precondition: simulate 19 bytes of HTTP error body")
        try errorBody.write(to: accessDeniedURL, options: .atomic)

        let mockSession = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(19, 19)],
                    result: .success(accessDeniedURL)
                )
            ]
        )

        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 20_000_000_000,
            requiresZipArchive: true
        )

        do {
            _ = try await service.ensureModelAvailable()
            XCTFail("Expected invalidArchive error when a non-zip payload is served in production mode")
        } catch let error as ModelDownloadServiceError {
            XCTAssertEqual(error, .invalidArchive, "Non-zip payload in production mode must throw .invalidArchive")
        }

        let gateStillLocked = await service.canUseTacticalFeatures()
        XCTAssertFalse(gateStillLocked, "Gate must remain closed after a rejected non-zip payload")
        let reportedDirectoryPath = await service.downloadedModelDirectoryPath()
        XCTAssertNil(
            reportedDirectoryPath,
            "No downloaded model path should be reported after a rejected non-zip payload"
        )

        let modelDirectory = sandbox.appSupportDirectory
            .appendingPathComponent(makeModelDownloadConfiguration().modelDirectoryName, isDirectory: true)
        let sentinelURL = modelDirectory.appendingPathComponent(makeModelDownloadConfiguration().modelFileName, isDirectory: false)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sentinelURL.path),
            "Sentinel file must NOT exist after a rejected non-zip payload"
        )
    }

    func testEnsureModelAvailableAcceptsNonZipPayloadInTestMode() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        // Mirror the fixture pattern used by the other existing model-download
        // tests: a tiny non-zip "model" file. In test mode
        // (requiresZipArchive == false) this path remains supported so the
        // existing mock-based coverage keeps working.
        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let mockSession = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(500, 1_000), (1_000, 1_000)],
                    result: .success(temporaryModelFile)
                )
            ]
        )

        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 20_000_000_000,
            requiresZipArchive: false
        )

        _ = try await service.ensureModelAvailable()

        let gateUnlocked = await service.canUseTacticalFeatures()
        XCTAssertTrue(gateUnlocked, "Test-mode non-zip payload should still unlock the gate")

        let resolvedDirectoryPath = await service.downloadedModelDirectoryPath()
        let directoryPath = try XCTUnwrap(resolvedDirectoryPath)
        let sentinelURL = URL(fileURLWithPath: directoryPath)
            .appendingPathComponent(makeModelDownloadConfiguration().modelFileName, isDirectory: false)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinelURL.path),
            "Test-mode non-zip install should persist the sentinel file"
        )
    }

    func testCactusModelInitializationIsGatedUntilDownloadCompletesThenUsesDownloadedPath() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let mockSession = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(500, 1_000), (1_000, 1_000)],
                    result: .success(temporaryModelFile)
                )
            ]
        )

        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 20_000_000_000
        )

        let initPathCollector = LockedArray<String>()
        let expectedHandleAddress = UInt(bitPattern: 0xFEEDBEEF)
        let initializer = CactusModelInitializationService(
            downloadService: service,
            initFunction: { modelPath, _, _ in
                initPathCollector.append(modelPath)
                return UnsafeMutableRawPointer(bitPattern: expectedHandleAddress)!
            },
            destroyFunction: { _ in }
        )

        do {
            _ = try await initializer.initializeModel()
            XCTFail("Expected download gate to block initialization before model is downloaded")
        } catch let error as CactusModelInitializationError {
            guard case .downloadIncomplete = error else {
                return XCTFail("Expected downloadIncomplete error, got \(error)")
            }
        }

        XCTAssertTrue(initPathCollector.values.isEmpty, "cactusInit should not run while download gate is locked")

        _ = try await service.ensureModelAvailable()
        let handle = try await initializer.initializeModel()
        XCTAssertEqual(handle, UnsafeMutableRawPointer(bitPattern: expectedHandleAddress))
        let initPaths = initPathCollector.values
        XCTAssertEqual(initPaths.count, 1)
        let downloadedDirectory = await service.downloadedModelDirectoryPath()
        XCTAssertEqual(initPaths.first, downloadedDirectory)
    }

    func testAppBootstrapViewModelShowsModelNamePercentageAndBytesDuringDownload() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let mockSession = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(500, 1_000)],
                    result: .success(temporaryModelFile),
                    responseDelayNanoseconds: 300_000_000
                )
            ]
        )

        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 20_000_000_000
        )

        let viewModel = await MainActor.run { AppBootstrapViewModel(downloadService: service) }
        await MainActor.run { viewModel.startIfNeeded() }

        let reachedMidDownload = await waitForCondition(timeout: 1.0) {
            await MainActor.run { viewModel.downloadProgress >= 0.5 && !viewModel.isDownloadComplete }
        }
        XCTAssertTrue(reachedMidDownload, "Expected in-progress state before download finishes")

        let modelName = await MainActor.run { viewModel.modelName }
        let percentLabel = await MainActor.run { viewModel.progressLabel }
        let bytesLabel = await MainActor.run { viewModel.byteProgressLabel }
        XCTAssertTrue(modelName.contains("Gemma"), "Download UI should show model name")
        XCTAssertTrue(percentLabel.contains("%"), "Download UI should show progress percentage")
        XCTAssertTrue(bytesLabel.contains("/"), "Download UI should show downloaded and total bytes")
    }

    func testAppBootstrapViewModelBlocksTacticalFeaturesDuringDownloadAndUnlocksWithinThreeSeconds() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let mockSession = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(100, 1_000), (600, 1_000)],
                    result: .success(temporaryModelFile),
                    responseDelayNanoseconds: 500_000_000
                )
            ]
        )

        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 20_000_000_000
        )

        let viewModel = await MainActor.run { AppBootstrapViewModel(downloadService: service) }
        await MainActor.run { viewModel.startIfNeeded() }

        let initiallyBlocked = await MainActor.run { !viewModel.isDownloadComplete }
        XCTAssertTrue(initiallyBlocked, "Tactical features must be blocked until download completes")

        let unlockedWithinThreeSeconds = await waitForCondition(timeout: 3.0) {
            await MainActor.run { viewModel.isDownloadComplete }
        }
        XCTAssertTrue(unlockedWithinThreeSeconds, "Features should unlock within 3 seconds of completion")
    }

    func testAppBootstrapViewModelShowsClearStorageErrorBeforeDownloadStarts() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let mockSession = MockURLSessionDownloadClient(scriptedResponses: [])
        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 1_000_000_000
        )

        let viewModel = await MainActor.run { AppBootstrapViewModel(downloadService: service) }
        await MainActor.run { viewModel.startIfNeeded() }

        let errorAppeared = await waitForCondition(timeout: 1.0) {
            await MainActor.run { viewModel.errorMessage != nil }
        }
        XCTAssertTrue(errorAppeared, "Download gate should show an error when storage is insufficient")

        let errorMessage = await MainActor.run { viewModel.errorMessage }
        let resolvedMessage = try XCTUnwrap(errorMessage)
        XCTAssertTrue(resolvedMessage.contains("Insufficient storage"))
        XCTAssertTrue(resolvedMessage.contains("Free up"))
        XCTAssertEqual(mockSession.requestCount, 0, "Storage failure should happen before any network requests")
        let gateStillLocked = await MainActor.run { !viewModel.isDownloadComplete }
        XCTAssertTrue(gateStillLocked)
    }

    func testAppBootstrapViewModelRetryResumesInterruptedDownloadFromPriorPoint() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let resumeData = Data("resume-checkpoint".utf8)
        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let mockSession = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(620, 1_000)],
                    result: .failure(URLSessionDownloadClientError.interrupted(resumeData: resumeData))
                ),
                .init(
                    progressEvents: [(700, 1_000), (1_000, 1_000)],
                    result: .success(temporaryModelFile)
                )
            ]
        )

        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: mockSession,
            availableStorageBytes: 20_000_000_000
        )

        let viewModel = await MainActor.run { AppBootstrapViewModel(downloadService: service) }
        await MainActor.run { viewModel.startIfNeeded() }

        let interruptionSurfaced = await waitForCondition(timeout: 1.0) {
            await MainActor.run { viewModel.errorMessage != nil }
        }
        XCTAssertTrue(interruptionSurfaced)

        let progressAtInterruption = await MainActor.run { viewModel.downloadProgress }
        XCTAssertGreaterThanOrEqual(progressAtInterruption, 0.60)

        await MainActor.run { viewModel.retry() }
        let completedAfterRetry = await waitForCondition(timeout: 2.0) {
            await MainActor.run { viewModel.isDownloadComplete }
        }
        XCTAssertTrue(completedAfterRetry)
        XCTAssertEqual(mockSession.requestCount, 2)
        XCTAssertEqual(mockSession.request(at: 1)?.resumeData, resumeData, "Retry should resume using stored resume data")

        let finalProgress = await MainActor.run { viewModel.downloadProgress }
        XCTAssertGreaterThanOrEqual(finalProgress, progressAtInterruption, "Retry should continue from roughly the prior point")
    }

    func testTreeBuilderAddNodeCreatesUniqueUnclaimedChildAndIncrementsVersion() throws {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        let initialVersion = viewModel.currentVersion
        let rootID = viewModel.networkConfig.tree.id

        let firstChild = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Alpha Lead"))
        let secondChild = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Bravo Lead"))

        XCTAssertEqual(viewModel.currentVersion, initialVersion + 2)
        XCTAssertNotEqual(firstChild.id, secondChild.id, "Each added node should have a unique identifier")
        XCTAssertNil(firstChild.claimedBy, "Newly added node should be unclaimed")
        XCTAssertNil(secondChild.claimedBy, "Newly added node should be unclaimed")

        let rootChildren = TreeHelpers.children(of: rootID, in: viewModel.networkConfig.tree)
        XCTAssertEqual(rootChildren.map(\.id), [firstChild.id, secondChild.id])

        let serialized = try XCTUnwrap(viewModel.serializedTreeJSON())
        let decoded = try JSONDecoder().decode(TreeNode.self, from: Data(serialized.utf8))
        XCTAssertEqual(decoded.children.map(\.id), [firstChild.id, secondChild.id], "Tree JSON should preserve new children for BLE distribution")
    }

    func testTreeBuilderRemoveNodeCascadesDescendantsAndIncrementsVersion() throws {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        let rootID = viewModel.networkConfig.tree.id

        let alpha = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Alpha"))
        let alpha1 = try XCTUnwrap(viewModel.addNode(parentID: alpha.id, label: "Alpha-1"))
        let alpha2 = try XCTUnwrap(viewModel.addNode(parentID: alpha.id, label: "Alpha-2"))

        let versionBeforeRemove = viewModel.currentVersion
        XCTAssertTrue(viewModel.removeNode(nodeID: alpha.id))
        XCTAssertEqual(viewModel.currentVersion, versionBeforeRemove + 1, "Successful remove should increment version by exactly one")

        XCTAssertNil(TreeHelpers.level(of: alpha.id, in: viewModel.networkConfig.tree))
        XCTAssertNil(TreeHelpers.level(of: alpha1.id, in: viewModel.networkConfig.tree))
        XCTAssertNil(TreeHelpers.level(of: alpha2.id, in: viewModel.networkConfig.tree))
    }

    func testTreeBuilderRenameNodeSupportsUnicodeEmojiAndIncrementsVersion() throws {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        let rootID = viewModel.networkConfig.tree.id
        let node = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Node"))

        let unicodeLabel = "🛰️ Recon 팀 – 北侧"
        let versionBeforeRename = viewModel.currentVersion
        XCTAssertTrue(viewModel.renameNode(nodeID: node.id, newLabel: unicodeLabel))
        XCTAssertEqual(viewModel.currentVersion, versionBeforeRename + 1, "Successful rename should increment version by exactly one")

        let renamedNode = try XCTUnwrap(viewModel.node(withID: node.id))
        XCTAssertEqual(renamedNode.label, unicodeLabel)
    }

    func testTreeBuilderVersionIncrementsByOnePerSuccessfulOperation() throws {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        let rootID = viewModel.networkConfig.tree.id

        let start = viewModel.currentVersion
        let child = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Alpha"))
        XCTAssertEqual(viewModel.currentVersion, start + 1)

        XCTAssertTrue(viewModel.renameNode(nodeID: child.id, newLabel: "Alpha 🟢"))
        XCTAssertEqual(viewModel.currentVersion, start + 2)

        XCTAssertTrue(viewModel.removeNode(nodeID: child.id))
        XCTAssertEqual(viewModel.currentVersion, start + 3)
    }

    func testTreeBuilderEmptyTreeHandlingIsGracefulAndSerializable() throws {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        XCTAssertFalse(viewModel.isTreeEmpty)

        viewModel.clearTree()
        XCTAssertTrue(viewModel.isTreeEmpty, "Cleared tree should be represented as an empty state")

        let serialized = try XCTUnwrap(viewModel.serializedTreeJSON())
        let decoded = try JSONDecoder().decode(TreeNode.self, from: Data(serialized.utf8))
        XCTAssertEqual(decoded.children.count, 0)
        XCTAssertEqual(decoded.label, "")
        XCTAssertNil(decoded.claimedBy)

        let recoveredNode = try XCTUnwrap(viewModel.addNode(parentID: decoded.id, label: "Recovered Node"))
        XCTAssertEqual(recoveredNode.label, "Recovered Node")
        XCTAssertFalse(viewModel.isTreeEmpty)
    }

    func testTreeBuilderDeepTreeFourPlusLevelsSerializesCorrectly() throws {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        let rootID = viewModel.networkConfig.tree.id

        let l1 = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "L1"))
        let l2 = try XCTUnwrap(viewModel.addNode(parentID: l1.id, label: "L2"))
        let l3 = try XCTUnwrap(viewModel.addNode(parentID: l2.id, label: "L3"))
        let l4 = try XCTUnwrap(viewModel.addNode(parentID: l3.id, label: "L4"))
        _ = try XCTUnwrap(viewModel.addNode(parentID: l4.id, label: "L5"))

        let serialized = try XCTUnwrap(viewModel.serializedTreeJSON())
        let decodedTree = try JSONDecoder().decode(TreeNode.self, from: Data(serialized.utf8))
        XCTAssertEqual(TreeHelpers.level(of: l4.id, in: decodedTree), 4, "Tree with 4+ levels should round-trip through JSON correctly")
    }

    func testTreeBuilderNetworkIDUniquenessAcrossManyNetworks() {
        let ids = Set((0..<1_000).map { index in
            TreeBuilderViewModel(
                networkName: "Net-\(index)",
                createdBy: "organiser-\(index)"
            ).networkConfig.networkID
        })

        XCTAssertEqual(ids.count, 1_000, "Each network should be assigned a unique UUID")
    }

    func testTreeBuilderConcurrentEditsProduceMonotonicVersionsWithoutGaps() {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        let rootID = viewModel.networkConfig.tree.id
        let startVersion = viewModel.currentVersion
        let editCount = 40

        let queue = DispatchQueue(label: "TacNet.TreeBuilder.ConcurrentEdits", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<editCount {
            group.enter()
            queue.async {
                _ = viewModel.renameNode(nodeID: rootID, newLabel: "Commander-\(index)")
                group.leave()
            }
        }

        group.wait()

        XCTAssertEqual(viewModel.currentVersion, startVersion + editCount)
        let expectedVersions = Array((startVersion + 1)...(startVersion + editCount))
        XCTAssertEqual(Array(viewModel.versionHistory.suffix(editCount)), expectedVersions, "Concurrent edits should still produce a strictly monotonic, gap-free version sequence")
    }

    func testTreeBuilderDragDropReorderSiblingsUpdatesOrderAndVersion() throws {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        let rootID = viewModel.networkConfig.tree.id

        let alpha = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Alpha"))
        let bravo = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Bravo"))
        let charlie = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Charlie"))

        let versionBeforeReorder = viewModel.currentVersion
        XCTAssertTrue(viewModel.reorderNode(nodeID: charlie.id, beforeSiblingID: alpha.id))
        XCTAssertEqual(viewModel.currentVersion, versionBeforeReorder + 1)

        let orderedChildren = TreeHelpers.children(of: rootID, in: viewModel.networkConfig.tree).map(\.id)
        XCTAssertEqual(orderedChildren, [charlie.id, alpha.id, bravo.id], "Dragging Charlie above Alpha should reorder siblings to [Charlie, Alpha, Bravo]")
    }

    func testTreeBuilderDragDropReparentMovesNodeAndPreservesSubtree() throws {
        let viewModel = TreeBuilderViewModel(networkName: "Operation Nightfall", createdBy: "organiser-device")
        let rootID = viewModel.networkConfig.tree.id

        let alpha = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Alpha"))
        let alphaChild = try XCTUnwrap(viewModel.addNode(parentID: alpha.id, label: "Alpha-1"))
        let bravo = try XCTUnwrap(viewModel.addNode(parentID: rootID, label: "Bravo"))

        let versionBeforeMove = viewModel.currentVersion
        XCTAssertTrue(viewModel.moveNode(nodeID: alpha.id, newParentID: bravo.id))
        XCTAssertEqual(viewModel.currentVersion, versionBeforeMove + 1)

        let movedParentID = TreeHelpers.parent(of: alpha.id, in: viewModel.networkConfig.tree)?.id
        XCTAssertEqual(movedParentID, bravo.id)
        XCTAssertEqual(TreeHelpers.parent(of: alphaChild.id, in: viewModel.networkConfig.tree)?.id, alpha.id, "Reparenting should preserve the dragged node's subtree")
    }

    @MainActor
    func testTreeSyncServiceHigherVersionWinsAndLowerVersionDiscarded() async {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)

        let networkID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let local = makeNetworkConfig(networkID: networkID, version: 3, rootLabel: "Local")
        syncService.setLocalConfig(local)

        let incomingHigher = makeNetworkConfig(networkID: networkID, version: 6, rootLabel: "Incoming Higher")
        let resultHigher = syncService.converge(with: incomingHigher)
        XCTAssertEqual(resultHigher, .replacedWithHigherVersion(previousVersion: 3, appliedVersion: 6))
        XCTAssertEqual(syncService.localConfig?.version, 6)
        XCTAssertEqual(syncService.localConfig?.tree.label, "Incoming Higher")

        let incomingLower = makeNetworkConfig(networkID: networkID, version: 4, rootLabel: "Incoming Lower")
        let resultLower = syncService.converge(with: incomingLower)
        XCTAssertEqual(resultLower, .ignoredStale(localVersion: 6, incomingVersion: 4))
        XCTAssertEqual(syncService.localConfig?.version, 6)
        XCTAssertEqual(syncService.localConfig?.tree.label, "Incoming Higher")
    }

    @MainActor
    func testTreeSyncServiceOutOfOrderUpdatesConvergeToHighestVersion() async {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)

        let networkID = UUID(uuidString: "ABCDEFAB-1234-5678-90AB-ABCDEFABCDEF")!
        syncService.setLocalConfig(makeNetworkConfig(networkID: networkID, version: 1, rootLabel: "v1"))

        let v3 = makeNetworkConfig(networkID: networkID, version: 3, rootLabel: "v3")
        let v7 = makeNetworkConfig(networkID: networkID, version: 7, rootLabel: "v7")
        let v5 = makeNetworkConfig(networkID: networkID, version: 5, rootLabel: "v5")

        XCTAssertEqual(syncService.converge(with: v3), .replacedWithHigherVersion(previousVersion: 1, appliedVersion: 3))
        XCTAssertEqual(syncService.converge(with: v7), .replacedWithHigherVersion(previousVersion: 3, appliedVersion: 7))
        XCTAssertEqual(syncService.converge(with: v5), .ignoredStale(localVersion: 7, incomingVersion: 5))
        XCTAssertEqual(syncService.localConfig?.version, 7)
        XCTAssertEqual(syncService.localConfig?.tree.label, "v7")
    }

    @MainActor
    func testTreeSyncServiceSameVersionIsNoOp() async {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)

        let networkID = UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")!
        syncService.setLocalConfig(makeNetworkConfig(networkID: networkID, version: 4, rootLabel: "Local v4"))

        let sameVersionDifferentTree = makeNetworkConfig(networkID: networkID, version: 4, rootLabel: "Incoming v4")
        let result = syncService.converge(with: sameVersionDifferentTree)

        XCTAssertEqual(result, .ignoredStale(localVersion: 4, incomingVersion: 4))
        XCTAssertEqual(syncService.localConfig?.version, 4)
        XCTAssertEqual(syncService.localConfig?.tree.label, "Local v4", "Same-version updates should be a no-op")
    }

    @MainActor
    func testTreeSyncServiceAutoReparentsChildrenToNearestConnectedAncestorAfterDisconnectTimeout() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService, disconnectTimeout: 0.05)
        let forwardingPeer = UUID(uuidString: "12121212-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let rootPeer = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!
        let alphaPeer = UUID(uuidString: "BBBB0000-0000-0000-0000-000000000001")!
        let bravoPeer = UUID(uuidString: "CCCC0000-0000-0000-0000-000000000001")!
        let charliePeer = UUID(uuidString: "DDDD0000-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(rootPeer, .connected))
        transport.emit(.connectionStateChanged(alphaPeer, .connected))
        transport.emit(.connectionStateChanged(bravoPeer, .connected))
        transport.emit(.connectionStateChanged(charliePeer, .connected))

        let config = makeAutoReparentNetworkConfig(
            networkID: UUID(uuidString: "ABCDEFFF-0000-0000-0000-000000000001")!,
            version: 20,
            rootOwnerID: rootPeer.uuidString,
            alphaOwnerID: alphaPeer.uuidString,
            bravoOwnerID: bravoPeer.uuidString,
            charlieOwnerID: charliePeer.uuidString
        )
        syncService.setLocalConfig(config)

        transport.emit(.connectionStateChanged(bravoPeer, .disconnected))
        syncService.handlePeerStateChange(peerID: bravoPeer, state: .disconnected)

        XCTAssertEqual(
            TreeHelpers.parent(of: "charlie", in: try XCTUnwrap(syncService.localConfig?.tree))?.id,
            "bravo",
            "Before the timeout elapses, the child should remain under the disconnected parent."
        )

        try await Task.sleep(nanoseconds: 250_000_000)

        let updatedConfig = try XCTUnwrap(syncService.localConfig)
        XCTAssertEqual(TreeHelpers.parent(of: "charlie", in: updatedConfig.tree)?.id, "alpha")
        XCTAssertEqual(updatedConfig.version, 21)

        XCTAssertEqual(transport.sentPackets.count, 1)
        let treeUpdate = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(treeUpdate.type, .treeUpdate)
        XCTAssertEqual(treeUpdate.parentID, "alpha")
        XCTAssertEqual(treeUpdate.payload.networkVersion, 21)
        XCTAssertEqual(TreeHelpers.parent(of: "charlie", in: try XCTUnwrap(treeUpdate.payload.tree))?.id, "alpha")
    }

    @MainActor
    func testTreeSyncServiceAutoReparentUpdatesCompactionRoutingToNewParent() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService, disconnectTimeout: 0.05)
        let forwardingPeer = UUID(uuidString: "13131313-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let rootPeer = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000002")!
        let alphaPeer = UUID(uuidString: "BBBB0000-0000-0000-0000-000000000002")!
        let bravoPeer = UUID(uuidString: "CCCC0000-0000-0000-0000-000000000002")!
        let charliePeer = UUID(uuidString: "DDDD0000-0000-0000-0000-000000000002")!
        transport.emit(.connectionStateChanged(rootPeer, .connected))
        transport.emit(.connectionStateChanged(alphaPeer, .connected))
        transport.emit(.connectionStateChanged(bravoPeer, .connected))
        transport.emit(.connectionStateChanged(charliePeer, .connected))

        let config = makeAutoReparentNetworkConfig(
            networkID: UUID(uuidString: "ABCDEFFF-0000-0000-0000-000000000002")!,
            version: 30,
            rootOwnerID: rootPeer.uuidString,
            alphaOwnerID: alphaPeer.uuidString,
            bravoOwnerID: bravoPeer.uuidString,
            charlieOwnerID: charliePeer.uuidString
        )
        syncService.setLocalConfig(config)

        let router = MessageRouter()
        let before = router.makeCompactionMessage(
            summary: "Charlie reports contact near sector 8.",
            senderID: "charlie",
            senderNodeID: "charlie",
            senderRole: "Charlie",
            in: config.tree
        )
        XCTAssertEqual(before.parentID, "bravo")
        XCTAssertTrue(router.shouldDisplay(before, for: "bravo", in: config.tree))
        XCTAssertFalse(router.shouldDisplay(before, for: "alpha", in: config.tree))

        transport.emit(.connectionStateChanged(bravoPeer, .disconnected))
        syncService.handlePeerStateChange(peerID: bravoPeer, state: .disconnected)
        try await Task.sleep(nanoseconds: 250_000_000)

        let updatedTree = try XCTUnwrap(syncService.localConfig?.tree)
        let after = router.makeCompactionMessage(
            summary: "Charlie reports contact near sector 8.",
            senderID: "charlie",
            senderNodeID: "charlie",
            senderRole: "Charlie",
            in: updatedTree
        )

        XCTAssertEqual(after.parentID, "alpha")
        XCTAssertTrue(router.shouldDisplay(after, for: "alpha", in: updatedTree))
        XCTAssertFalse(router.shouldDisplay(after, for: "bravo", in: updatedTree))
    }

    @MainActor
    func testTreeSyncServiceAutoReparentHandlesCascadingDisconnectsAcrossMultipleLevels() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService, disconnectTimeout: 0.05)
        let forwardingPeer = UUID(uuidString: "14141414-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let rootPeer = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000003")!
        let alphaPeer = UUID(uuidString: "BBBB0000-0000-0000-0000-000000000003")!
        let bravoPeer = UUID(uuidString: "CCCC0000-0000-0000-0000-000000000003")!
        let charliePeer = UUID(uuidString: "DDDD0000-0000-0000-0000-000000000003")!
        transport.emit(.connectionStateChanged(rootPeer, .connected))
        transport.emit(.connectionStateChanged(alphaPeer, .connected))
        transport.emit(.connectionStateChanged(bravoPeer, .connected))
        transport.emit(.connectionStateChanged(charliePeer, .connected))

        let config = makeAutoReparentNetworkConfig(
            networkID: UUID(uuidString: "ABCDEFFF-0000-0000-0000-000000000003")!,
            version: 40,
            rootOwnerID: rootPeer.uuidString,
            alphaOwnerID: alphaPeer.uuidString,
            bravoOwnerID: bravoPeer.uuidString,
            charlieOwnerID: charliePeer.uuidString
        )
        syncService.setLocalConfig(config)

        transport.emit(.connectionStateChanged(bravoPeer, .disconnected))
        syncService.handlePeerStateChange(peerID: bravoPeer, state: .disconnected)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(TreeHelpers.parent(of: "charlie", in: try XCTUnwrap(syncService.localConfig?.tree))?.id, "alpha")

        transport.emit(.connectionStateChanged(alphaPeer, .disconnected))
        syncService.handlePeerStateChange(peerID: alphaPeer, state: .disconnected)
        try await Task.sleep(nanoseconds: 250_000_000)

        let finalConfig = try XCTUnwrap(syncService.localConfig)
        XCTAssertEqual(TreeHelpers.parent(of: "charlie", in: finalConfig.tree)?.id, "root")

        var parentIDs: [String] = []
        for packet in transport.sentPackets {
            let message = try decodeMessage(from: packet.data)
            guard message.type == .treeUpdate else {
                continue
            }
            if let parentID = message.parentID {
                parentIDs.append(parentID)
            }
        }
        XCTAssertTrue(parentIDs.contains("alpha"), "Expected first cascade step to reparent under Alpha.")
        XCTAssertTrue(parentIDs.contains("root"), "Expected second cascade step to reparent under Root.")
    }

    func testNetworkEncryptionServiceEncryptDecryptRoundTripWithPinDerivedSessionKey() throws {
        let organiserService = NetworkEncryptionService()
        let participantService = NetworkEncryptionService()
        let networkID = UUID(uuidString: "12341234-5678-90AB-CDEF-1234567890AB")!
        let pinHash = try XCTUnwrap(NetworkConfig.hashPIN("2468"))
        let keyMaterial = NetworkEncryptionService.keyMaterial(pinHash: pinHash, networkID: networkID)

        let wrappedSessionKey = try organiserService.makeWrappedSessionKey(
            networkID: networkID,
            keyMaterial: keyMaterial
        )
        try participantService.activateSessionKey(
            networkID: networkID,
            wrappedSessionKey: wrappedSessionKey,
            keyMaterial: keyMaterial
        )

        let plaintext = Data("CONTACT east at bridge checkpoint".utf8)
        let encryptedPayload = try organiserService.encryptTransportPayload(plaintext)

        XCTAssertNil(
            encryptedPayload.range(of: plaintext),
            "Encrypted payload should not contain plaintext fragments"
        )

        let decryptedPayload = try participantService.decryptTransportPayload(encryptedPayload)
        XCTAssertEqual(decryptedPayload, plaintext)
    }

    func testNetworkEncryptionServiceWrongKeyRejectionPreventsPayloadAccess() throws {
        let organiserService = NetworkEncryptionService()
        let unauthorizedService = NetworkEncryptionService()
        let networkID = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        let correctHash = try XCTUnwrap(NetworkConfig.hashPIN("1357"))
        let wrongHash = try XCTUnwrap(NetworkConfig.hashPIN("0000"))

        let correctMaterial = NetworkEncryptionService.keyMaterial(pinHash: correctHash, networkID: networkID)
        let wrongMaterial = NetworkEncryptionService.keyMaterial(pinHash: wrongHash, networkID: networkID)
        let wrappedSessionKey = try organiserService.makeWrappedSessionKey(
            networkID: networkID,
            keyMaterial: correctMaterial
        )

        XCTAssertThrowsError(
            try unauthorizedService.activateSessionKey(
                networkID: networkID,
                wrappedSessionKey: wrappedSessionKey,
                keyMaterial: wrongMaterial
            )
        ) { error in
            XCTAssertEqual(error as? NetworkEncryptionError, .decryptionFailed)
        }

        let encryptedPayload = try organiserService.encryptTransportPayload(Data("casualty at north ridge".utf8))
        XCTAssertThrowsError(try unauthorizedService.decryptTransportPayload(encryptedPayload)) { error in
            XCTAssertEqual(error as? NetworkEncryptionError, .missingSessionKey)
        }
    }

    func testNetworkEncryptionServiceLogSafetyAvoidsPINAndKeyMaterialLeakage() throws {
        let logger = CapturingSecurityLogger()
        let service = NetworkEncryptionService(logger: logger)
        let networkID = UUID(uuidString: "FEE1DEAD-BEEF-1234-5678-90ABCDEF1234")!
        let pin = "4321"
        let pinHash = try XCTUnwrap(NetworkConfig.hashPIN(pin))
        let keyMaterial = NetworkEncryptionService.keyMaterial(pinHash: pinHash, networkID: networkID)

        let wrappedSessionKey = try service.makeWrappedSessionKey(
            networkID: networkID,
            keyMaterial: keyMaterial
        )
        _ = try? service.activateSessionKey(
            networkID: networkID,
            wrappedSessionKey: wrappedSessionKey,
            keyMaterial: "incorrect-\(keyMaterial)"
        )

        let combinedLogs = logger.messages.joined(separator: "\n").lowercased()
        XCTAssertFalse(combinedLogs.isEmpty)
        XCTAssertFalse(combinedLogs.contains(pin.lowercased()))
        XCTAssertFalse(combinedLogs.contains(pinHash.lowercased()))
        XCTAssertFalse(combinedLogs.contains(keyMaterial.lowercased()))
        XCTAssertFalse(combinedLogs.contains(wrappedSessionKey.lowercased()))
    }

    @MainActor
    func testTreeSyncJoinRejectsWrongPINAndDoesNotLeakTree() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)

        let peerID = UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!
        let remote = makeNetworkConfig(
            networkID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            version: 2,
            rootLabel: "Sensitive Tree",
            pin: "1234"
        )
        transport.setTreeConfig(remote, for: peerID)

        let discovered = DiscoveredNetwork(
            peerID: peerID,
            networkID: remote.networkID,
            networkName: remote.networkName,
            openSlotCount: remote.openSlotCount,
            requiresPIN: true
        )

        do {
            _ = try await syncService.join(network: discovered, pin: "0000")
            XCTFail("Expected invalid PIN rejection")
        } catch let error as TreeSyncJoinError {
            XCTAssertEqual(error, .invalidPIN)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertNil(syncService.localConfig, "Tree should not be stored locally when PIN is invalid")
    }

    @MainActor
    func testTreeSyncJoinAllowsDirectJoinForPINLessNetwork() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)

        let peerID = UUID(uuidString: "BBBBBBBB-1111-2222-3333-CCCCCCCCCCCC")!
        let remote = makeNetworkConfig(
            networkID: UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!,
            version: 9,
            rootLabel: "PIN-less Tree",
            pin: nil
        )
        transport.setTreeConfig(remote, for: peerID)

        let discovered = DiscoveredNetwork(
            peerID: peerID,
            networkID: remote.networkID,
            networkName: remote.networkName,
            openSlotCount: remote.openSlotCount,
            requiresPIN: false
        )

        let joined = try await syncService.join(network: discovered, pin: nil)
        XCTAssertEqual(joined.networkID, remote.networkID)
        XCTAssertEqual(joined.version, remote.version)
        XCTAssertEqual(joined.tree.label, "PIN-less Tree")
        XCTAssertEqual(syncService.localConfig?.networkID, remote.networkID)
    }

    @MainActor
    func testRoleClaimServiceClaimOpenNodePublishesClaimAndUpdatesTree() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let forwardingPeer = UUID(uuidString: "0A0A0A0A-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let networkID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        syncService.setLocalConfig(makeNetworkConfig(networkID: networkID, version: 1, rootLabel: "Role Tree"))

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )

        let result = roleService.claim(nodeID: "alpha")
        XCTAssertEqual(result, .claimed(nodeID: "alpha"))
        XCTAssertEqual(claimedByValue(nodeID: "alpha", in: syncService.localConfig), "local-device")

        XCTAssertEqual(transport.sentPackets.count, 1)
        let published = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(published.type, .claim)
        XCTAssertEqual(published.payload.claimedNodeID, "alpha")
    }

    @MainActor
    func testRoleClaimServiceClaimAlreadyClaimedNodeRejectedAndPreservesExistingClaim() {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let networkID = UUID(uuidString: "77777777-8888-9999-AAAA-BBBBBBBBBBBB")!
        syncService.setLocalConfig(makeNetworkConfig(networkID: networkID, version: 2, rootLabel: "Role Tree"))

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "contender-device",
            disconnectTimeout: 60
        )

        let result = roleService.claim(nodeID: "bravo")
        XCTAssertEqual(result, .rejected(reason: .alreadyClaimed))
        XCTAssertEqual(claimedByValue(nodeID: "bravo", in: syncService.localConfig), "claimed-device")
        XCTAssertEqual(transport.sentPackets.count, 0)
    }

    @MainActor
    func testRoleClaimServiceOrganiserRejectsConflictWithOrganiserWinsReason() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let forwardingPeer = UUID(uuidString: "0B0B0B0B-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000001")!
        var config = makeNetworkConfig(networkID: networkID, version: 3, rootLabel: "Role Tree")
        config.createdBy = "organiser-device"
        config = withClaim(nodeID: "alpha", claimedBy: "organiser-device", in: config)
        syncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )

        let incomingConflict = Message.make(
            type: .claim,
            senderID: "participant-2",
            senderRole: "participant",
            parentID: "root",
            treeLevel: 1,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            claimedNodeID: "alpha"
        )

        roleService.handleIncomingMessage(incomingConflict)

        XCTAssertEqual(claimedByValue(nodeID: "alpha", in: syncService.localConfig), "organiser-device")
        XCTAssertEqual(transport.sentPackets.count, 1)

        let rejection = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(rejection.type, .claimRejected)
        XCTAssertEqual(rejection.payload.claimedNodeID, "alpha")
        XCTAssertEqual(rejection.payload.targetNodeID, "participant-2")
        XCTAssertEqual(rejection.payload.rejectionReason, ClaimRejectionReason.organiserWins.rawValue)
    }

    @MainActor
    func testRoleClaimServiceManualReleasePublishesReleaseAndOpensNode() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let forwardingPeer = UUID(uuidString: "0C0C0C0C-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000002")!
        var config = makeNetworkConfig(networkID: networkID, version: 4, rootLabel: "Role Tree")
        config = withClaim(nodeID: "alpha", claimedBy: "local-device", in: config)
        syncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )

        let result = roleService.releaseActiveClaim()
        XCTAssertEqual(result, .released(nodeID: "alpha"))
        XCTAssertNil(claimedByValue(nodeID: "alpha", in: syncService.localConfig))

        XCTAssertEqual(transport.sentPackets.count, 1)
        let releaseMessage = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(releaseMessage.type, .release)
        XCTAssertEqual(releaseMessage.payload.claimedNodeID, "alpha")
    }

    @MainActor
    func testRoleClaimServiceAutoReleaseAfterDisconnectTimeout() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let forwardingPeer = UUID(uuidString: "0D0D0D0D-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let disconnectedPeer = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001")!
        let disconnectedDeviceID = disconnectedPeer.uuidString

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000003")!
        var config = makeNetworkConfig(networkID: networkID, version: 5, rootLabel: "Role Tree")
        config.createdBy = "organiser-device"
        config = withClaim(nodeID: "alpha", claimedBy: disconnectedDeviceID, in: config)
        syncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "organiser-device",
            disconnectTimeout: 0.05
        )

        roleService.handlePeerStateChange(peerID: disconnectedPeer, state: .disconnected)
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNil(claimedByValue(nodeID: "alpha", in: syncService.localConfig))
        XCTAssertEqual(transport.sentPackets.count, 1)

        let releaseMessage = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(releaseMessage.type, .release)
        XCTAssertEqual(releaseMessage.payload.claimedNodeID, "alpha")
        XCTAssertEqual(releaseMessage.senderID, disconnectedDeviceID)
    }

    @MainActor
    func testRoleClaimServicePromoteFailsForUnclaimedParticipant() {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000004")!
        syncService.setLocalConfig(makeNetworkConfig(networkID: networkID, version: 6, rootLabel: "Role Tree"))

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )

        XCTAssertThrowsError(try roleService.validatePromoteTarget(nodeID: "alpha")) { error in
            XCTAssertEqual(error as? PromoteValidationError, .targetUnclaimed)
        }
    }

    @MainActor
    func testRoleClaimServiceLiveAddBroadcastsTreeUpdateWithIncrementedVersion() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let forwardingPeer = UUID(uuidString: "0E0E0E0E-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000005")!
        var config = makeNetworkConfig(networkID: networkID, version: 7, rootLabel: "Role Tree")
        config.createdBy = "organiser-device"
        syncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )

        let startingVersion = try XCTUnwrap(syncService.localConfig?.version)
        let createdNode = roleService.addNode(parentID: "root", label: "Delta")
        let createdNodeID = try XCTUnwrap(createdNode?.id)

        let updatedConfig = try XCTUnwrap(syncService.localConfig)
        XCTAssertEqual(updatedConfig.version, startingVersion + 1)
        XCTAssertEqual(findNode(nodeID: createdNodeID, in: updatedConfig.tree)?.label, "Delta")

        XCTAssertEqual(transport.sentPackets.count, 1)
        let treeUpdate = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(treeUpdate.type, .treeUpdate)
        XCTAssertEqual(treeUpdate.payload.networkVersion, startingVersion + 1)
        XCTAssertEqual(findNode(nodeID: createdNodeID, in: try XCTUnwrap(treeUpdate.payload.tree))?.label, "Delta")
    }

    @MainActor
    func testRoleClaimServiceLiveRemoveClaimedNodeKicksClaimantWithNotification() throws {
        let organiserTransport = MockBluetoothMeshTransport()
        let organiserMesh = BluetoothMeshService(transport: organiserTransport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let organiserSync = TreeSyncService(meshService: organiserMesh)
        let forwardingPeer = UUID(uuidString: "0F0F0F0F-0000-0000-0000-000000000001")!
        organiserTransport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000006")!
        var config = makeNetworkConfig(networkID: networkID, version: 8, rootLabel: "Role Tree")
        config.createdBy = "organiser-device"
        config = withClaim(nodeID: "alpha", claimedBy: "participant-device", in: config)
        organiserSync.setLocalConfig(config)

        let organiserService = RoleClaimService(
            meshService: organiserMesh,
            treeSyncService: organiserSync,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )

        let participantTransport = MockBluetoothMeshTransport()
        let participantMesh = BluetoothMeshService(transport: participantTransport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let participantSync = TreeSyncService(meshService: participantMesh)
        participantSync.setLocalConfig(config)
        let participantService = RoleClaimService(
            meshService: participantMesh,
            treeSyncService: participantSync,
            localDeviceID: "participant-device",
            disconnectTimeout: 60
        )

        XCTAssertEqual(participantService.activeClaimNodeID, "alpha")
        XCTAssertTrue(organiserService.removeNode(nodeID: "alpha"))

        XCTAssertNil(claimedByValue(nodeID: "alpha", in: organiserSync.localConfig))
        XCTAssertEqual(organiserTransport.sentPackets.count, 1)

        let treeUpdate = try decodeMessage(from: organiserTransport.sentPackets[0].data)
        XCTAssertEqual(treeUpdate.type, .treeUpdate)
        participantService.handleIncomingMessage(treeUpdate)

        XCTAssertNil(participantService.activeClaimNodeID)
        XCTAssertTrue(participantService.requiresRoleReselection)
        XCTAssertEqual(participantService.roleReselectionNotification, "Your claimed role was removed from the tree.")
        XCTAssertEqual(participantService.lastClaimRejection, .nodeNotFound)
    }

    @MainActor
    func testRoleClaimServiceLiveRenameBroadcastsTreeUpdateAndPreservesUnchangedClaims() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let forwardingPeer = UUID(uuidString: "10101010-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000007")!
        var config = makeNetworkConfig(networkID: networkID, version: 9, rootLabel: "Role Tree")
        config.createdBy = "organiser-device"
        syncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )

        XCTAssertTrue(roleService.renameNode(nodeID: "alpha", newLabel: "Alpha Prime"))

        let updatedConfig = try XCTUnwrap(syncService.localConfig)
        XCTAssertEqual(findNode(nodeID: "alpha", in: updatedConfig.tree)?.label, "Alpha Prime")
        XCTAssertEqual(claimedByValue(nodeID: "bravo", in: updatedConfig), "claimed-device")

        XCTAssertEqual(transport.sentPackets.count, 1)
        let treeUpdate = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(treeUpdate.type, .treeUpdate)
    }

    @MainActor
    func testRoleClaimServiceLiveMoveBroadcastsTreeUpdateAndPreservesMovedNodeClaim() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)
        let forwardingPeer = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000008")!
        var config = makeNetworkConfig(networkID: networkID, version: 10, rootLabel: "Role Tree")
        config.createdBy = "organiser-device"
        config = withClaim(nodeID: "alpha", claimedBy: "moved-device", in: config)
        syncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )

        XCTAssertTrue(roleService.moveNode(nodeID: "alpha", newParentID: "bravo"))

        let updatedConfig = try XCTUnwrap(syncService.localConfig)
        XCTAssertEqual(TreeHelpers.parent(of: "alpha", in: updatedConfig.tree)?.id, "bravo")
        XCTAssertEqual(claimedByValue(nodeID: "alpha", in: updatedConfig), "moved-device")

        XCTAssertEqual(transport.sentPackets.count, 1)
        let treeUpdate = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(treeUpdate.type, .treeUpdate)
        XCTAssertEqual(TreeHelpers.parent(of: "alpha", in: try XCTUnwrap(treeUpdate.payload.tree))?.id, "bravo")
    }

    @MainActor
    func testRoleClaimServiceTreeUpdatePreservesExistingClaimsWhenIncomingTreeOmitsThem() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let syncService = TreeSyncService(meshService: meshService)

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000009")!
        var config = makeNetworkConfig(networkID: networkID, version: 11, rootLabel: "Role Tree")
        config.createdBy = "organiser-device"
        config = withClaim(nodeID: "alpha", claimedBy: "participant-device", in: config)
        syncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: "participant-device",
            disconnectTimeout: 60
        )

        var incomingTree = config.tree
        _ = mutateClaim(nodeID: "alpha", claimedBy: nil, in: &incomingTree)
        incomingTree.children.append(TreeNode(id: "charlie", label: "Charlie", claimedBy: nil, children: []))

        let treeUpdate = Message.make(
            type: .treeUpdate,
            senderID: "organiser-device",
            senderRole: "organiser",
            parentID: "root",
            treeLevel: 0,
            ttl: 8,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            tree: incomingTree,
            networkVersion: config.version + 1
        )

        roleService.handleIncomingMessage(treeUpdate)

        let updatedConfig = try XCTUnwrap(syncService.localConfig)
        XCTAssertEqual(claimedByValue(nodeID: "alpha", in: updatedConfig), "participant-device")
        XCTAssertNotNil(findNode(nodeID: "charlie", in: updatedConfig.tree))
    }

    @MainActor
    func testRoleClaimServicePromoteTransfersOrganiserPermissionsAtomically() throws {
        let organiserTransport = MockBluetoothMeshTransport()
        let organiserMesh = BluetoothMeshService(transport: organiserTransport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let organiserSync = TreeSyncService(meshService: organiserMesh)
        let forwardingPeer = UUID(uuidString: "12121212-0000-0000-0000-000000000001")!
        organiserTransport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let networkID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-00000000000A")!
        var config = makeNetworkConfig(networkID: networkID, version: 12, rootLabel: "Role Tree")
        config.createdBy = "old-organiser-device"
        config = withClaim(nodeID: "alpha", claimedBy: "new-organiser-device", in: config)
        organiserSync.setLocalConfig(config)

        let organiserService = RoleClaimService(
            meshService: organiserMesh,
            treeSyncService: organiserSync,
            localDeviceID: "old-organiser-device",
            disconnectTimeout: 60
        )

        XCTAssertTrue(organiserService.promote(nodeID: "alpha"))
        XCTAssertFalse(organiserService.isOrganiser)
        XCTAssertEqual(organiserSync.localConfig?.createdBy, "new-organiser-device")

        XCTAssertEqual(organiserTransport.sentPackets.count, 1)
        let promoteMessage = try decodeMessage(from: organiserTransport.sentPackets[0].data)
        XCTAssertEqual(promoteMessage.type, .promote)
        XCTAssertEqual(promoteMessage.payload.targetNodeID, "alpha")
        XCTAssertEqual(promoteMessage.payload.networkVersion, config.version + 1)

        let promotedTransport = MockBluetoothMeshTransport()
        let promotedMesh = BluetoothMeshService(transport: promotedTransport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let promotedSync = TreeSyncService(meshService: promotedMesh)
        promotedSync.setLocalConfig(config)
        let promotedService = RoleClaimService(
            meshService: promotedMesh,
            treeSyncService: promotedSync,
            localDeviceID: "new-organiser-device",
            disconnectTimeout: 60
        )

        promotedService.handleIncomingMessage(promoteMessage)

        XCTAssertEqual(promotedSync.localConfig?.createdBy, "new-organiser-device")
        XCTAssertTrue(promotedService.isOrganiser)
    }

    @MainActor
    func testMainViewModelFeedShowsSiblingBroadcastAndCompactionEntriesOrderedNewestFirst() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let treeSync = TreeSyncService(meshService: meshService)

        var config = NetworkConfig(
            networkName: "TacNet Live Feed",
            networkID: UUID(uuidString: "ABABABAB-1234-5678-90AB-ABABABABABAB")!,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        _ = mutateClaim(nodeID: "alpha", claimedBy: "local-device", in: &config.tree)
        treeSync.setLocalConfig(config)

        let roleClaimService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSync,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )
        let audioService = AudioService(
            capturer: MockAudioCapturer(clips: []),
            transcriber: MockCactusTranscriber(results: []),
            maxRecordingDuration: 60
        )
        let viewModel = MainViewModel(
            meshService: meshService,
            roleClaimService: roleClaimService,
            localDeviceID: "local-device",
            audioService: audioService
        )

        let olderCompaction = Message.make(
            id: UUID(uuidString: "11111111-AAAA-BBBB-CCCC-111111111111")!,
            type: .compaction,
            senderID: "alpha-1",
            senderRole: "Alpha 1",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            summary: "Alpha child compaction summary",
            timestamp: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let newerSiblingBroadcast = Message.make(
            id: UUID(uuidString: "22222222-AAAA-BBBB-CCCC-222222222222")!,
            type: .broadcast,
            senderID: "bravo",
            senderRole: "Bravo",
            parentID: "root",
            treeLevel: 1,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Bravo sibling update",
            timestamp: Date(timeIntervalSince1970: 1_700_000_050)
        )
        let filteredOutCousinBroadcast = Message.make(
            id: UUID(uuidString: "33333333-AAAA-BBBB-CCCC-333333333333")!,
            type: .broadcast,
            senderID: "charlie-1",
            senderRole: "Charlie 1",
            parentID: "charlie",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Should not appear for alpha",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100)
        )

        viewModel.handleIncomingMessage(olderCompaction)
        viewModel.handleIncomingMessage(filteredOutCousinBroadcast)
        viewModel.handleIncomingMessage(newerSiblingBroadcast)

        XCTAssertEqual(viewModel.feedEntries.count, 2, "Feed should include sibling broadcasts and compactions, excluding unrelated broadcasts")
        XCTAssertEqual(viewModel.feedEntries.map(\.type), [.broadcast, .compaction], "Newest entry should be first")
        XCTAssertEqual(viewModel.feedEntries.first?.text, "Bravo sibling update")
        XCTAssertEqual(viewModel.feedEntries.last?.text, "Alpha child compaction summary")
        XCTAssertEqual(viewModel.feedEntries.first?.senderRole, "Bravo")
        XCTAssertEqual(viewModel.feedEntries.last?.senderRole, "Alpha 1")
    }

    @MainActor
    func testMainViewModelPTTStateMachineCyclesIdleRecordingSendingIdleAndPublishesBroadcast() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let treeSync = TreeSyncService(meshService: meshService)

        var config = NetworkConfig(
            networkName: "TacNet PTT",
            networkID: UUID(uuidString: "CDCDCDCD-1234-5678-90AB-CDCDCDCDCDCD")!,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        _ = mutateClaim(nodeID: "alpha-2", claimedBy: "local-device", in: &config.tree)
        treeSync.setLocalConfig(config)

        let roleClaimService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSync,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )

        let clip = makeAlternatingPCMClip(sampleCount: 500, amplitude: 2_000)
        let audioService = AudioService(
            capturer: MockAudioCapturer(clips: [clip]),
            transcriber: MockCactusTranscriber(
                results: ["Alpha two reporting contact east"],
                delayNanoseconds: 120_000_000
            ),
            maxRecordingDuration: 60
        )

        let viewModel = MainViewModel(
            meshService: meshService,
            roleClaimService: roleClaimService,
            localDeviceID: "local-device",
            audioService: audioService
        )

        let connectedPeer = UUID(uuidString: "F0F0F0F0-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(connectedPeer, .connected))
        viewModel.handlePeerConnectionStateChanged(peerID: connectedPeer, state: .connected)

        XCTAssertEqual(viewModel.pttState, .idle)
        XCTAssertFalse(viewModel.isPTTDisabled)

        await viewModel.startPushToTalk()
        XCTAssertEqual(viewModel.pttState, .recording)

        let stopTask = Task {
            await viewModel.stopPushToTalk()
        }

        let enteredSending = await waitForCondition(timeout: 1.0) {
            await MainActor.run {
                viewModel.pttState == .sending
            }
        }
        XCTAssertTrue(enteredSending, "PTT state should pass through sending while transcription and publish run")

        await stopTask.value
        XCTAssertEqual(viewModel.pttState, .idle)
        XCTAssertNil(viewModel.errorMessage)

        XCTAssertEqual(transport.sentPackets.count, 1)
        let outbound = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(outbound.type, .broadcast)
        XCTAssertEqual(outbound.payload.transcript, "Alpha two reporting contact east")
        XCTAssertEqual(outbound.senderID, "local-device")
        XCTAssertEqual(outbound.parentID, "alpha")
    }

    @MainActor
    func testMainViewModelPTTDisabledWhenDisconnectedAndShowsError() async {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let treeSync = TreeSyncService(meshService: meshService)

        var config = NetworkConfig(
            networkName: "TacNet Disconnected",
            networkID: UUID(uuidString: "EFEFEFEF-1234-5678-90AB-EFEFEFEFEFEF")!,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        _ = mutateClaim(nodeID: "alpha-2", claimedBy: "local-device", in: &config.tree)
        treeSync.setLocalConfig(config)

        let roleClaimService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSync,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )

        let viewModel = MainViewModel(
            meshService: meshService,
            roleClaimService: roleClaimService,
            localDeviceID: "local-device",
            audioService: AudioService(
                capturer: MockAudioCapturer(clips: [makeAlternatingPCMClip(sampleCount: 300, amplitude: 1_000)]),
                transcriber: MockCactusTranscriber(results: ["should-not-send"]),
                maxRecordingDuration: 60
            )
        )

        XCTAssertTrue(viewModel.isPTTDisabled)
        await viewModel.startPushToTalk()

        XCTAssertEqual(viewModel.pttState, .idle)
        XCTAssertEqual(viewModel.errorMessage, "Disconnected from mesh. Reconnect to use push-to-talk.")
        XCTAssertTrue(viewModel.isPTTDisabled)
        XCTAssertTrue(transport.sentPackets.isEmpty, "No message should be sent while disconnected")
    }

    // MARK: PTT gesture dispatcher

    /// Regression for the real-device bug where pressing and holding the PTT button did not
    /// dispatch to `MainViewModel.startPushToTalk` / `stopPushToTalk` (iOS reported
    /// `Gesture: System gesture gate timed out.`). We now drive press/release transitions
    /// through a `PTTPressDispatcher` that the `PTTButtonStyle` uses to dedupe SwiftUI's
    /// repeated `configuration.isPressed` notifications. This test verifies that the
    /// dispatcher wires onPressBegan / onPressEnded exactly once per physical press.
    @MainActor
    func testPTTPressDispatcherFiresOnPressBeganAndOnPressEndedExactlyOncePerPress() {
        var beganCount = 0
        var endedCount = 0
        let dispatcher = PTTPressDispatcher(
            onPressBegan: { beganCount += 1 },
            onPressEnded: { endedCount += 1 }
        )

        // Initial state: no press in progress.
        XCTAssertFalse(dispatcher.isPressed)
        XCTAssertEqual(beganCount, 0)
        XCTAssertEqual(endedCount, 0)

        // Single transition to pressed fires onPressBegan exactly once.
        dispatcher.updatePressState(isPressed: true)
        XCTAssertTrue(dispatcher.isPressed)
        XCTAssertEqual(beganCount, 1)
        XCTAssertEqual(endedCount, 0)

        // Repeated `true` deliveries must NOT re-fire onPressBegan (SwiftUI can
        // redeliver `isPressed=true` during body refreshes).
        dispatcher.updatePressState(isPressed: true)
        dispatcher.updatePressState(isPressed: true)
        XCTAssertEqual(beganCount, 1, "onPressBegan must fire only once per physical press")
        XCTAssertEqual(endedCount, 0)

        // Transition to released fires onPressEnded exactly once.
        dispatcher.updatePressState(isPressed: false)
        XCTAssertFalse(dispatcher.isPressed)
        XCTAssertEqual(beganCount, 1)
        XCTAssertEqual(endedCount, 1)

        // Repeated `false` deliveries must NOT re-fire onPressEnded.
        dispatcher.updatePressState(isPressed: false)
        dispatcher.updatePressState(isPressed: false)
        XCTAssertEqual(beganCount, 1)
        XCTAssertEqual(endedCount, 1, "onPressEnded must fire only once per physical release")

        // A second press/release cycle produces a second pair of exactly-one events.
        dispatcher.updatePressState(isPressed: true)
        XCTAssertEqual(beganCount, 2)
        XCTAssertEqual(endedCount, 1)
        dispatcher.updatePressState(isPressed: false)
        XCTAssertEqual(beganCount, 2)
        XCTAssertEqual(endedCount, 2)
    }

    @MainActor
    func testAfterActionReviewStoreRoundTripPersistsBroadcastAndCompactionMetadata() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("SwiftData requires iOS 17+")
        }

        let store = try SwiftDataAfterActionReviewStore(isStoredInMemoryOnly: true)
        store.purgeAll()

        let broadcast = Message.make(
            id: UUID(uuidString: "9F000000-1111-2222-3333-444444444444")!,
            type: .broadcast,
            senderID: "alpha-1-device",
            senderRole: "Alpha 1",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: 34.1201,
            longitude: -117.3210,
            accuracy: 3.4,
            transcript: "Contact observed near bridge checkpoint.",
            timestamp: Date(timeIntervalSince1970: 1_701_200_000)
        )
        let compaction = Message.make(
            id: UUID(uuidString: "AF000000-1111-2222-3333-444444444444")!,
            type: .compaction,
            senderID: "alpha-lead-device",
            senderRole: "Alpha Lead",
            parentID: "root",
            treeLevel: 1,
            ttl: 4,
            encrypted: false,
            latitude: 34.1210,
            longitude: -117.3200,
            accuracy: 4.9,
            summary: "Bridge checkpoint secured, one casualty evacuated.",
            timestamp: Date(timeIntervalSince1970: 1_701_200_100)
        )

        store.persist(broadcast)
        store.persist(compaction)

        let stored = store.allMessages()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.map(\.id), [compaction.id, broadcast.id], "Newest messages should appear first")

        let newest = try XCTUnwrap(stored.first)
        XCTAssertEqual(newest.senderRole, "Alpha Lead")
        XCTAssertEqual(newest.type, .compaction)
        XCTAssertEqual(newest.body, "Bridge checkpoint secured, one casualty evacuated.")
        XCTAssertEqual(newest.latitude, 34.1210, accuracy: 0.000001)
        XCTAssertEqual(newest.longitude, -117.3200, accuracy: 0.000001)
        XCTAssertEqual(newest.accuracy, 4.9, accuracy: 0.000001)
    }

    @MainActor
    func testAfterActionReviewStoreSurvivesStoreReinitialization() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("SwiftData requires iOS 17+")
        }

        let firstStore = try SwiftDataAfterActionReviewStore(isStoredInMemoryOnly: false)
        firstStore.purgeAll()

        let persistedMessage = Message.make(
            id: UUID(uuidString: "BF000000-1111-2222-3333-444444444444")!,
            type: .broadcast,
            senderID: "bravo-device",
            senderRole: "Bravo",
            parentID: "root",
            treeLevel: 1,
            ttl: 4,
            encrypted: false,
            latitude: 35.001,
            longitude: -118.001,
            accuracy: 6.0,
            transcript: "Emergency call at north ridge.",
            timestamp: Date(timeIntervalSince1970: 1_701_210_000)
        )
        firstStore.persist(persistedMessage)
        XCTAssertEqual(firstStore.search(query: "emergency").count, 1)

        let relaunchedStore = try SwiftDataAfterActionReviewStore(isStoredInMemoryOnly: false)
        let resultsAfterRelaunch = relaunchedStore.search(query: "EMERGENCY")

        XCTAssertEqual(resultsAfterRelaunch.count, 1, "Message should survive store recreation")
        XCTAssertEqual(resultsAfterRelaunch.first?.id, persistedMessage.id)
        XCTAssertEqual(resultsAfterRelaunch.first?.senderRole, "Bravo")

        relaunchedStore.purgeAll()
    }

    @MainActor
    func testAfterActionReviewStoreSearchIsCaseInsensitiveAcrossBroadcastAndCompaction() throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("SwiftData requires iOS 17+")
        }

        let store = try SwiftDataAfterActionReviewStore(isStoredInMemoryOnly: true)
        store.purgeAll()

        store.persist(
            Message.make(
                id: UUID(uuidString: "CF000000-1111-2222-3333-444444444444")!,
                type: .broadcast,
                senderID: "charlie-1-device",
                senderRole: "Charlie 1",
                parentID: "charlie",
                treeLevel: 2,
                ttl: 4,
                encrypted: false,
                latitude: nil,
                longitude: nil,
                accuracy: nil,
                transcript: "Need CASUALTY evacuation at checkpoint."
            )
        )
        store.persist(
            Message.make(
                id: UUID(uuidString: "DF000000-1111-2222-3333-444444444444")!,
                type: .compaction,
                senderID: "charlie-lead-device",
                senderRole: "Charlie Lead",
                parentID: "root",
                treeLevel: 1,
                ttl: 4,
                encrypted: false,
                latitude: 36.1,
                longitude: -119.4,
                accuracy: 7.2,
                summary: "Casualty stabilized and extraction route established."
            )
        )
        store.persist(
            Message.make(
                id: UUID(uuidString: "EF000000-1111-2222-3333-444444444444")!,
                type: .broadcast,
                senderID: "delta-device",
                senderRole: "Delta",
                parentID: "root",
                treeLevel: 1,
                ttl: 4,
                encrypted: false,
                latitude: nil,
                longitude: nil,
                accuracy: nil,
                transcript: "Routine status green."
            )
        )

        let matches = store.search(query: "casualty")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(Set(matches.map(\.type)), [.broadcast, .compaction])
        XCTAssertTrue(matches.allSatisfy { !$0.senderRole.isEmpty })
        XCTAssertTrue(matches.allSatisfy { !$0.body.isEmpty })
        XCTAssertTrue(matches.allSatisfy { $0.timestamp.timeIntervalSince1970 > 0 })
        XCTAssertTrue(store.search(query: "nonsense-does-not-exist").isEmpty)
    }

    @MainActor
    func testAfterActionReviewViewModelSearchUpdatesResultsWithMetadata() {
        let store = InMemoryAfterActionReviewStore()
        let viewModel = AfterActionReviewViewModel(store: store)

        viewModel.record(
            Message.make(
                id: UUID(uuidString: "F1000000-1111-2222-3333-444444444444")!,
                type: .broadcast,
                senderID: "echo-device",
                senderRole: "Echo",
                parentID: "root",
                treeLevel: 1,
                ttl: 4,
                encrypted: false,
                latitude: 33.0,
                longitude: -117.0,
                accuracy: 5.0,
                transcript: "Checkpoint clear and route open."
            )
        )
        viewModel.query = "route"

        XCTAssertEqual(viewModel.results.count, 1)
        XCTAssertEqual(viewModel.results.first?.senderRole, "Echo")
        XCTAssertEqual(viewModel.results.first?.type, .broadcast)
        XCTAssertEqual(viewModel.totalMessageCount, 1)
    }

    func testTabNavigationDefinesAllFourTabsInExpectedOrder() {
        XCTAssertEqual(TacNetTab.allCases.count, 4)
        XCTAssertEqual(TacNetTab.allCases.map(\.title), ["Main", "Tree View", "Data Flow", "Settings"])
    }

    @MainActor
    func testSettingsViewModelRoleBasedVisibilityForOrganiserAndParticipant() {
        let organiserContext = makeRoleClaimContextForSettings(
            localDeviceID: "organiser-device",
            createdBy: "organiser-device",
            claims: ["alpha": "organiser-device"]
        )
        let organiserViewModel = SettingsViewModel(roleClaimService: organiserContext.roleService)

        XCTAssertTrue(organiserViewModel.showsOrganiserControls)
        XCTAssertTrue(organiserViewModel.isEditTreeButtonVisible)
        XCTAssertFalse(organiserViewModel.isEditTreeButtonDisabled)

        let participantContext = makeRoleClaimContextForSettings(
            localDeviceID: "participant-device",
            createdBy: "organiser-device",
            claims: ["alpha": "participant-device"]
        )
        let participantViewModel = SettingsViewModel(roleClaimService: participantContext.roleService)

        XCTAssertFalse(participantViewModel.showsOrganiserControls)
        XCTAssertFalse(participantViewModel.isEditTreeButtonVisible)
        XCTAssertTrue(participantViewModel.isEditTreeButtonDisabled)
    }

    @MainActor
    func testSettingsViewModelReleaseRoleBroadcastsReleaseAndClearsClaim() throws {
        let context = makeRoleClaimContextForSettings(
            localDeviceID: "local-device",
            createdBy: "organiser-device",
            claims: ["alpha": "local-device"]
        )
        let viewModel = SettingsViewModel(roleClaimService: context.roleService)

        XCTAssertTrue(viewModel.canReleaseRole)
        XCTAssertTrue(viewModel.releaseRole())
        XCTAssertFalse(viewModel.canReleaseRole)
        XCTAssertEqual(viewModel.statusMessage, "Released alpha.")

        XCTAssertNil(claimedByValue(nodeID: "alpha", in: context.syncService.localConfig))
        XCTAssertEqual(context.transport.sentPackets.count, 1)
        let releaseMessage = try decodeMessage(from: context.transport.sentPackets[0].data)
        XCTAssertEqual(releaseMessage.type, .release)
        XCTAssertEqual(releaseMessage.payload.claimedNodeID, "alpha")
    }

    @MainActor
    func testSettingsViewModelOrganiserCanAddRenameAndRemoveNodesFromSettings() throws {
        let context = makeRoleClaimContextForSettings(
            localDeviceID: "organiser-device",
            createdBy: "organiser-device"
        )
        let viewModel = SettingsViewModel(roleClaimService: context.roleService)

        viewModel.selectedNodeID = "root"
        viewModel.newChildLabelDraft = "Delta"
        XCTAssertTrue(viewModel.addChildToSelectedNode())

        let createdNodeID = try XCTUnwrap(viewModel.selectedNodeID)
        XCTAssertEqual(findNode(nodeID: createdNodeID, in: try XCTUnwrap(context.syncService.localConfig).tree)?.label, "Delta")

        viewModel.renameDraft = "Delta Prime"
        XCTAssertTrue(viewModel.renameSelectedNode())
        XCTAssertEqual(findNode(nodeID: createdNodeID, in: try XCTUnwrap(context.syncService.localConfig).tree)?.label, "Delta Prime")

        XCTAssertTrue(viewModel.removeSelectedNode())
        XCTAssertNil(findNode(nodeID: createdNodeID, in: try XCTUnwrap(context.syncService.localConfig).tree))

        let sentTypes = try context.transport.sentPackets.map { try decodeMessage(from: $0.data).type }
        XCTAssertEqual(sentTypes, [.treeUpdate, .treeUpdate, .treeUpdate])
    }

    @MainActor
    func testSettingsViewModelPromoteFromSettingsTransfersOrganiserPrivileges() throws {
        let context = makeRoleClaimContextForSettings(
            localDeviceID: "old-organiser-device",
            createdBy: "old-organiser-device",
            claims: ["alpha": "new-organiser-device"]
        )
        let viewModel = SettingsViewModel(roleClaimService: context.roleService)

        viewModel.promoteTargetNodeID = "alpha"
        XCTAssertTrue(viewModel.promoteSelectedNode())
        XCTAssertEqual(context.syncService.localConfig?.createdBy, "new-organiser-device")
        XCTAssertFalse(viewModel.showsOrganiserControls)

        XCTAssertEqual(context.transport.sentPackets.count, 1)
        let promoteMessage = try decodeMessage(from: context.transport.sentPackets[0].data)
        XCTAssertEqual(promoteMessage.type, .promote)
        XCTAssertEqual(promoteMessage.payload.targetNodeID, "alpha")
    }

    @MainActor
    func testSettingsTreeEditorDragDropReparentBroadcastsTreeUpdate() throws {
        let context = makeRoleClaimContextForSettings(
            localDeviceID: "organiser-device",
            createdBy: "organiser-device"
        )
        let viewModel = SettingsViewModel(roleClaimService: context.roleService)

        XCTAssertTrue(viewModel.handleNodeDrop(draggedNodeID: "alpha-1", onto: "bravo"))

        let updatedConfig = try XCTUnwrap(context.syncService.localConfig)
        XCTAssertEqual(TreeHelpers.parent(of: "alpha-1", in: updatedConfig.tree)?.id, "bravo")

        XCTAssertEqual(context.transport.sentPackets.count, 1)
        let treeUpdate = try decodeMessage(from: context.transport.sentPackets[0].data)
        XCTAssertEqual(treeUpdate.type, .treeUpdate)
        let updatedTree = try XCTUnwrap(treeUpdate.payload.tree)
        XCTAssertEqual(TreeHelpers.parent(of: "alpha-1", in: updatedTree)?.id, "bravo")
    }

    @MainActor
    func testSettingsTreeEditorDragDropReorderBroadcastsTreeUpdateAndPersistsAcrossRestart() throws {
        let suiteName = "TacNetTests.NetworkConfigStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let networkConfigStore = NetworkConfigStore(
            defaults: defaults,
            storageKey: "TacNetTests.NetworkConfigStore.TreeOrder"
        )

        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(
            transport: transport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let treeSyncService = TreeSyncService(meshService: meshService, configStore: networkConfigStore)
        transport.emit(
            .connectionStateChanged(
                UUID(uuidString: "D0D0D0D0-0000-0000-0000-000000000002")!,
                .connected
            )
        )

        var config = NetworkConfig(
            networkName: "TacNet Settings",
            networkID: UUID(uuidString: "DEADBEEF-CAFE-BABE-FADE-000000000002")!,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        treeSyncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSyncService,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )
        let viewModel = SettingsViewModel(roleClaimService: roleService)

        XCTAssertTrue(viewModel.handleNodeDrop(draggedNodeID: "charlie", onto: "alpha"))

        config = try XCTUnwrap(treeSyncService.localConfig)
        XCTAssertEqual(TreeHelpers.children(of: "root", in: config.tree).map(\.id), ["charlie", "alpha", "bravo"])

        XCTAssertEqual(transport.sentPackets.count, 1)
        let treeUpdate = try decodeMessage(from: transport.sentPackets[0].data)
        XCTAssertEqual(treeUpdate.type, .treeUpdate)
        let updatedTree = try XCTUnwrap(treeUpdate.payload.tree)
        XCTAssertEqual(TreeHelpers.children(of: "root", in: updatedTree).map(\.id), ["charlie", "alpha", "bravo"])

        let restartedMesh = BluetoothMeshService(
            transport: MockBluetoothMeshTransport(),
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let restartedTreeSyncService = TreeSyncService(meshService: restartedMesh, configStore: networkConfigStore)
        let restartedConfig = try XCTUnwrap(restartedTreeSyncService.localConfig)
        XCTAssertEqual(TreeHelpers.children(of: "root", in: restartedConfig.tree).map(\.id), ["charlie", "alpha", "bravo"])
    }

    @MainActor
    func testDataFlowViewModelIncomingSectionListsReceivedMessagesWithMetadata() {
        let viewModel = DataFlowViewModel()
        let olderTimestamp = Date(timeIntervalSince1970: 1_700_800_010)
        let newerTimestamp = Date(timeIntervalSince1970: 1_700_800_050)

        let olderMessage = Message.make(
            id: UUID(uuidString: "AAAA0000-1111-2222-3333-444444444444")!,
            type: .claim,
            senderID: "alpha-device",
            senderRole: "Alpha Lead",
            parentID: "root",
            treeLevel: 1,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            timestamp: olderTimestamp
        )
        let newerMessage = Message.make(
            id: UUID(uuidString: "BBBB0000-1111-2222-3333-444444444444")!,
            type: .compaction,
            senderID: "bravo-1",
            senderRole: "Bravo 1",
            parentID: "bravo",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            summary: "Bravo compaction summary",
            timestamp: newerTimestamp
        )

        viewModel.handleIncomingMessage(olderMessage)
        viewModel.handleIncomingMessage(newerMessage)

        XCTAssertEqual(viewModel.incomingEntries.count, 2)
        XCTAssertEqual(viewModel.incomingEntries.map(\.messageID), [newerMessage.id, olderMessage.id])
        XCTAssertEqual(viewModel.incomingEntries.map(\.senderRole), ["Bravo 1", "Alpha Lead"])
        XCTAssertEqual(viewModel.incomingEntries.map(\.senderID), ["bravo-1", "alpha-device"])
        XCTAssertEqual(viewModel.incomingEntries.map(\.typeLabel), ["COMPACTION", "CLAIM"])
        XCTAssertEqual(viewModel.incomingEntries.map(\.timestamp), [newerTimestamp, olderTimestamp])
    }

    @MainActor
    func testDataFlowViewModelProcessingSectionShowsStatusAndAIMetricsWithinOneSecond() async throws {
        let viewModel = DataFlowViewModel()
        let summarizer = MockTacticalSummarizer(
            outputs: ["Alpha summary output with casualty and route update."],
            delayNanoseconds: 220_000_000
        )
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )

        await engine.setProcessingObserver { metrics in
            Task { @MainActor in
                viewModel.handleProcessingMetrics(metrics)
            }
        }

        let enqueueTask = Task {
            await engine.enqueueChildTranscript(
                "Alpha-1 reports two hostiles near checkpoint east and route blocked by debris.",
                from: "alpha-1"
            )
        }

        let compactingObserved = await waitForCondition(timeout: 1.0) {
            await MainActor.run {
                viewModel.processing.status == .compacting &&
                    viewModel.processing.triggerReason == .messageCount
            }
        }
        XCTAssertTrue(compactingObserved, "Expected compacting status within one second")

        await enqueueTask.value

        let idleObserved = await waitForCondition(timeout: 1.0) {
            await MainActor.run {
                viewModel.processing.status == .idle &&
                    viewModel.processing.latencyMilliseconds != nil
            }
        }
        XCTAssertTrue(idleObserved, "Expected idle status with latency metrics within one second")

        XCTAssertEqual(viewModel.processing.triggerReason, .messageCount)
        XCTAssertGreaterThan(viewModel.processing.inputTokenCount, 0)
        XCTAssertGreaterThan(viewModel.processing.outputTokenCount, 0)
        XCTAssertNotNil(viewModel.processing.compressionRatio)
        XCTAssertGreaterThan(viewModel.processing.latencyMilliseconds ?? 0, 0)
    }

    @MainActor
    func testDataFlowViewModelOutgoingSectionListsEveryEmittedCompaction() async throws {
        let viewModel = DataFlowViewModel()
        let summarizer = MockTacticalSummarizer(
            outputs: [
                "First emitted compaction output.",
                "Second emitted compaction output."
            ]
        )
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )

        await engine.setCompactionEmissionObserver { emission in
            Task { @MainActor in
                viewModel.handleOutgoingCompaction(emission)
            }
        }

        await engine.enqueueChildTranscript("Alpha-1 contact at grid seven.", from: "alpha-1")
        await engine.enqueueChildTranscript("Alpha-2 route secure at grid eight.", from: "alpha-2")

        let outgoingObserved = await waitForCondition(timeout: 1.0) {
            await MainActor.run {
                viewModel.outgoingEntries.count == 2
            }
        }
        XCTAssertTrue(outgoingObserved, "Expected outgoing compaction entries within one second")

        XCTAssertEqual(viewModel.outgoingEntries.count, 2)
        XCTAssertEqual(viewModel.outgoingEntries[0].destinationNodeID, "root")
        XCTAssertEqual(viewModel.outgoingEntries[0].sourceNodeIDs, ["alpha-2"])
        XCTAssertEqual(viewModel.outgoingEntries[0].outputText, "Second emitted compaction output.")
        XCTAssertEqual(viewModel.outgoingEntries[1].destinationNodeID, "root")
        XCTAssertEqual(viewModel.outgoingEntries[1].sourceNodeIDs, ["alpha-1"])
        XCTAssertEqual(viewModel.outgoingEntries[1].outputText, "First emitted compaction output.")
    }

    @MainActor
    func testTreeViewModelBuildsHierarchyAndShowsClaimedByLabels() {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let treeSync = TreeSyncService(meshService: meshService)

        var config = NetworkConfig(
            networkName: "TacNet Tree",
            networkID: UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        _ = mutateClaim(nodeID: "alpha", claimedBy: "alpha-device", in: &config.tree)
        treeSync.setLocalConfig(config)

        let roleClaimService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSync,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )

        let viewModel = TreeViewModel(
            roleClaimService: roleClaimService,
            localDeviceID: "local-device",
            nowProvider: { Date(timeIntervalSince1970: 1_700_500_000) }
        )

        let alphaRow = viewModel.rows.first(where: { $0.id == "alpha" })
        let bravoRow = viewModel.rows.first(where: { $0.id == "bravo" })
        let alphaOneRow = viewModel.rows.first(where: { $0.id == "alpha-1" })

        XCTAssertEqual(alphaRow?.depth, 1)
        XCTAssertEqual(alphaOneRow?.depth, 2)
        XCTAssertEqual(alphaRow?.claimedByText, "claimed_by: alpha-device")
        XCTAssertEqual(bravoRow?.claimedByText, "claimed_by: Available")
    }

    @MainActor
    func testTreeViewModelStatusTransitionsUseThirtyAndSixtySecondThresholds() {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let treeSync = TreeSyncService(meshService: meshService)
        treeSync.setLocalConfig(
            NetworkConfig(
                networkName: "TacNet Status",
                networkID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001")!,
                createdBy: "organiser-device",
                pinHash: nil,
                version: 1,
                tree: makeFixtureTree()
            )
        )

        let roleClaimService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSync,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )

        let baseTime = Date(timeIntervalSince1970: 1_700_600_000)
        let viewModel = TreeViewModel(
            roleClaimService: roleClaimService,
            localDeviceID: "local-device",
            nowProvider: { baseTime }
        )

        XCTAssertEqual(viewModel.status(for: "alpha", now: baseTime.addingTimeInterval(30)), .active)
        XCTAssertEqual(viewModel.status(for: "alpha", now: baseTime.addingTimeInterval(31)), .idle)
        XCTAssertEqual(viewModel.status(for: "alpha", now: baseTime.addingTimeInterval(60)), .idle)
        XCTAssertEqual(viewModel.status(for: "alpha", now: baseTime.addingTimeInterval(61)), .disconnected)
    }

    @MainActor
    func testTreeViewModelCompactionSummaryIsTruncatedAndExpandsOnToggle() {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(transport: transport, deduplicator: MessageDeduplicator(capacity: 1_000))
        let treeSync = TreeSyncService(meshService: meshService)
        treeSync.setLocalConfig(
            NetworkConfig(
                networkName: "TacNet Compaction",
                networkID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000002")!,
                createdBy: "organiser-device",
                pinHash: nil,
                version: 1,
                tree: makeFixtureTree()
            )
        )

        let roleClaimService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSync,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )

        let viewModel = TreeViewModel(
            roleClaimService: roleClaimService,
            localDeviceID: "local-device",
            nowProvider: { Date(timeIntervalSince1970: 1_700_700_000) }
        )

        let longSummary = "Alpha child reports two hostiles near ridge line, one casualty, route blocked by debris, and requests urgent support from Bravo squad immediately."
        let compactionMessage = Message.make(
            id: UUID(uuidString: "AAAA1111-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            type: .compaction,
            senderID: "alpha-1",
            senderRole: "Alpha 1",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            summary: longSummary,
            timestamp: Date(timeIntervalSince1970: 1_700_700_010)
        )

        viewModel.handleIncomingMessage(compactionMessage)

        let alphaBeforeExpand = viewModel.rows.first(where: { $0.id == "alpha" })
        XCTAssertNotNil(alphaBeforeExpand?.compactionDisplayText)
        XCTAssertNotEqual(alphaBeforeExpand?.compactionDisplayText, longSummary)
        XCTAssertTrue(alphaBeforeExpand?.compactionDisplayText?.hasSuffix("…") == true)

        viewModel.toggleCompactionExpansion(for: "alpha")
        let alphaAfterExpand = viewModel.rows.first(where: { $0.id == "alpha" })
        XCTAssertEqual(alphaAfterExpand?.compactionDisplayText, longSummary)
        XCTAssertTrue(alphaAfterExpand?.isCompactionExpanded == true)
    }

    func testAudioServiceAcceptsValidPCM16kMono16BitAndForwardsTranscript() async throws {
        let clip = makeAlternatingPCMClip(sampleCount: 400, amplitude: 1_200)
        let capturer = MockAudioCapturer(clips: [clip])
        let transcriber = MockCactusTranscriber(results: ["Alpha contact east"])
        let transcriptConsumer = MockTranscriptConsumer()
        let audioService = AudioService(
            capturer: capturer,
            transcriber: transcriber,
            transcriptConsumer: transcriptConsumer,
            maxRecordingDuration: 60
        )

        try await audioService.pttPressed()
        let queuedSequence = try await audioService.pttReleased()
        XCTAssertEqual(queuedSequence, 0)

        await audioService.waitForIdle()

        let history = await audioService.transcriptHistory
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.sequence, 0)
        XCTAssertEqual(history.first?.transcript, "Alpha contact east")

        let transcribedInputs = await transcriber.receivedPCMInputs()
        XCTAssertEqual(transcribedInputs, [clip.data])
        XCTAssertTrue(clip.isPCM16kMono16Bit)

        let consumed = await transcriptConsumer.received()
        XCTAssertEqual(consumed.count, 1)
        XCTAssertEqual(consumed.first?.transcript, "Alpha contact east")
    }

    func testAudioServiceSkipsEmptyAndSilenceAudioWithoutCreatingTranscript() async throws {
        let emptyClip = makePCMClip(samples: [])
        let silenceClip = makePCMClip(samples: Array(repeating: 0, count: 2_000))
        let capturer = MockAudioCapturer(clips: [emptyClip, silenceClip])
        let transcriber = MockCactusTranscriber(results: ["should-not-be-used"])
        let transcriptConsumer = MockTranscriptConsumer()
        let audioService = AudioService(
            capturer: capturer,
            transcriber: transcriber,
            transcriptConsumer: transcriptConsumer,
            maxRecordingDuration: 60
        )

        try await audioService.pttPressed()
        let firstResult = try await audioService.pttReleased()
        XCTAssertNil(firstResult, "Zero-length audio should not queue a transcript")

        try await audioService.pttPressed()
        let secondResult = try await audioService.pttReleased()
        XCTAssertNil(secondResult, "Silence-only audio should not queue a transcript")

        await audioService.waitForIdle()

        let history = await audioService.transcriptHistory
        let transcribedInputs = await transcriber.receivedPCMInputs()
        let consumed = await transcriptConsumer.received()
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(transcribedInputs.isEmpty)
        XCTAssertTrue(consumed.isEmpty)
    }

    func testAudioServiceSerializesRapidSequentialPTTWithoutCorruption() async throws {
        let clipA = makeAlternatingPCMClip(sampleCount: 360, amplitude: 1_000)
        let clipB = makeAlternatingPCMClip(sampleCount: 380, amplitude: 2_000)
        let clipC = makeAlternatingPCMClip(sampleCount: 400, amplitude: 3_000)
        let capturer = MockAudioCapturer(clips: [clipA, clipB, clipC])
        let transcriber = MockCactusTranscriber(
            results: ["first", "second", "third"],
            delayNanoseconds: 40_000_000
        )
        let transcriptConsumer = MockTranscriptConsumer()
        let audioService = AudioService(
            capturer: capturer,
            transcriber: transcriber,
            transcriptConsumer: transcriptConsumer,
            maxRecordingDuration: 60
        )

        try await audioService.pttPressed()
        _ = try await audioService.pttReleased()
        try await audioService.pttPressed()
        _ = try await audioService.pttReleased()
        try await audioService.pttPressed()
        _ = try await audioService.pttReleased()

        await audioService.waitForIdle()

        let history = await audioService.transcriptHistory
        XCTAssertEqual(history.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(history.map(\.transcript), ["first", "second", "third"])

        let transcribedInputs = await transcriber.receivedPCMInputs()
        XCTAssertEqual(transcribedInputs, [clipA.data, clipB.data, clipC.data], "Each rapid press should transcribe its own clip in order without data corruption")

        let consumed = await transcriptConsumer.received()
        XCTAssertEqual(consumed.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(consumed.map(\.transcript), ["first", "second", "third"])
    }

    func testAudioServiceCapsVeryLongAudioBeforeTranscription() async throws {
        let ninetySecondSampleCount = 16_000 * 90
        let longClip = makeAlternatingPCMClip(sampleCount: ninetySecondSampleCount, amplitude: 1_500)
        let capturer = MockAudioCapturer(clips: [longClip])
        let transcriber = MockCactusTranscriber(results: ["long clip transcript"])
        let transcriptConsumer = MockTranscriptConsumer()
        let audioService = AudioService(
            capturer: capturer,
            transcriber: transcriber,
            transcriptConsumer: transcriptConsumer,
            maxRecordingDuration: 60
        )

        try await audioService.pttPressed()
        _ = try await audioService.pttReleased()
        await audioService.waitForIdle()

        let transcribedInputs = await transcriber.receivedPCMInputs()
        let firstInput = try XCTUnwrap(transcribedInputs.first)
        XCTAssertEqual(firstInput.count, 16_000 * 60 * 2, "Audio should be capped to 60 seconds at 16kHz mono 16-bit")
        let history = await audioService.transcriptHistory
        XCTAssertEqual(history.count, 1)
    }

    func testCompactionEngineTimeWindowTriggerFiresAfterConfiguredWindow() async throws {
        let tree = makeFixtureTree()
        let summarizer = MockTacticalSummarizer(outputs: [
            "Grid 12 east hostile movement, Alpha holding."
        ])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: tree,
            summarizer: summarizer,
            configuration: .init(timeWindow: 0.05, messageCountThreshold: 5, defaultTTL: 6)
        )

        await engine.enqueueChildTranscript(
            "Alpha-1 reports hostile movement near grid 12 east; one hostile observed; status holding.",
            from: "alpha-1"
        )

        let triggered = await waitForCondition(timeout: 1.0) {
            let emissions = await engine.emittedCompactions()
            return emissions.count == 1
        }
        XCTAssertTrue(triggered, "Expected time-window trigger to emit a compaction")

        let emissions = await engine.emittedCompactions()
        let emission = try XCTUnwrap(emissions.first)
        XCTAssertEqual(emission.triggerReason, .timeWindow)
        XCTAssertEqual(emission.sourceMessageCount, 1)
        XCTAssertEqual(emission.message.type, .compaction)
        XCTAssertEqual(emission.message.parentID, "root")
        XCTAssertEqual(emission.message.ttl, 6)
    }

    func testCompactionEngineCountThresholdTriggersAtBoundary() async throws {
        let summarizer = MockTacticalSummarizer(outputs: ["Alpha sector summary with threat and status."])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 3, defaultTTL: 8)
        )

        await engine.enqueueChildTranscript("Alpha-1 movement at grid A1", from: "alpha-1")
        await engine.enqueueChildTranscript("Alpha-2 no visual on threat", from: "alpha-2")
        let emissionsBeforeThreshold = await engine.emittedCompactions()
        XCTAssertTrue(emissionsBeforeThreshold.isEmpty)

        await engine.enqueueChildTranscript("Alpha-1 status green", from: "alpha-1")
        let emissionsAfterThreshold = await engine.emittedCompactions()
        let emission = try XCTUnwrap(emissionsAfterThreshold.first)
        XCTAssertEqual(emission.triggerReason, .messageCount)
        XCTAssertEqual(emission.sourceMessageCount, 3)
    }

    func testCompactionEnginePriorityKeywordsTriggerImmediatelyCaseInsensitive() async throws {
        let summarizer = MockTacticalSummarizer(outputs: ["Emergency contact summary."])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 10, defaultTTL: 8)
        )

        await engine.enqueueChildTranscript("Patrol reports EMERGENCY near checkpoint bravo.", from: "alpha-1")

        let emissions = await engine.emittedCompactions()
        let emission = try XCTUnwrap(emissions.first)
        XCTAssertEqual(emission.triggerReason, .priorityKeyword)
        XCTAssertEqual(emission.sourceMessageCount, 1)
    }

    func testCompactionEnginePriorityKeywordPositionInvariantAndRejectsSubstrings() async throws {
        let summarizer = MockTacticalSummarizer(outputs: [
            "Start keyword summary",
            "Middle keyword summary",
            "End keyword summary"
        ])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 10, defaultTTL: 8)
        )

        await engine.enqueueChildTranscript("Contact observed at north ridge.", from: "alpha-1")
        await engine.enqueueChildTranscript("Alpha-2 reports casualty at waypoint 3.", from: "alpha-2")
        await engine.enqueueChildTranscript("Unit remains stable until emergency", from: "alpha-1")
        let keywordEmissions = await engine.emittedCompactions()
        XCTAssertEqual(keywordEmissions.count, 3, "Keyword should trigger at start/middle/end")

        await engine.enqueueChildTranscript("Alpha team contacted support and moved out.", from: "alpha-1")
        await engine.enqueueChildTranscript("Subcontract convoy passing through corridor.", from: "alpha-2")
        await engine.enqueueChildTranscript("Make contact lens appointment after patrol.", from: "alpha-1")
        await engine.enqueueChildTranscript("Emergency exit sign reported in admin building.", from: "alpha-2")
        await engine.enqueueChildTranscript("Casualties expected if weather worsens.", from: "alpha-1")
        let finalEmissions = await engine.emittedCompactions()
        XCTAssertEqual(
            finalEmissions.count,
            3,
            "Substring and known benign phrase matches must not trigger immediate compaction"
        )
    }

    func testCompactionEngineSummaryIsUnderThirtyWordsWithoutFillerAndKeepsCriticalInfo() async throws {
        let summarizer = MockTacticalSummarizer(outputs: [
            """
            Uh um copy that roger say again over. Grid nine east has two hostiles and one casualty. \
            Alpha squad status stable while Bravo secures extraction route immediately.
            """
        ])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )

        await engine.enqueueChildTranscript(
            "Grid nine east reports two hostiles, one casualty, Alpha stable, Bravo securing extraction.",
            from: "alpha-1"
        )

        let emissions = await engine.emittedCompactions()
        let emission = try XCTUnwrap(emissions.first)
        let summary = try XCTUnwrap(emission.message.payload.summary)
        XCTAssertLessThanOrEqual(summary.split(whereSeparator: \.isWhitespace).count, 30)

        let lowered = summary.lowercased()
        ["uh", "um", "copy that", "roger", "say again", "over"].forEach { filler in
            XCTAssertFalse(lowered.contains(filler), "Summary should remove filler phrase: \(filler)")
        }
        XCTAssertTrue(lowered.contains("grid"))
        XCTAssertTrue(lowered.contains("hostiles"))
        XCTAssertTrue(lowered.contains("status"))
    }

    func testCompactionEngineSingleMessageCompactionIsValid() async throws {
        let summarizer = MockTacticalSummarizer(outputs: [
            "Grid seven north contact suppressed, one casualty stable, Alpha holding perimeter."
        ])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )

        await engine.enqueueChildTranscript("Alpha-1 contact grid seven north, casualty stable.", from: "alpha-1")

        let emissions = await engine.emittedCompactions()
        let emission = try XCTUnwrap(emissions.first)
        XCTAssertEqual(emission.sourceMessageCount, 1)
        XCTAssertLessThanOrEqual(
            (emission.message.payload.summary ?? "").split(whereSeparator: \.isWhitespace).count,
            30
        )
    }

    func testCompactionEngineHandlesTwentyMessagesWithoutDroppingContext() async throws {
        let summarizer = MockTacticalSummarizer(outputs: ["Twenty-message tactical compaction summary."])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 20, defaultTTL: 8)
        )

        for index in 1...20 {
            await engine.enqueueChildTranscript("Report \(index): status update at grid \(index).", from: "alpha-1")
        }

        let emissions = await engine.emittedCompactions()
        let emission = try XCTUnwrap(emissions.first)
        XCTAssertEqual(emission.sourceMessageCount, 20)

        let invocations = await summarizer.invocations()
        let prompt = try XCTUnwrap(invocations.first?.userPrompt.lowercased())
        XCTAssertTrue(prompt.contains("report 1"))
        XCTAssertTrue(prompt.contains("report 20"))
    }

    func testCompactionEngineUsesTacticalSummarizerPromptRequirements() async throws {
        let summarizer = MockTacticalSummarizer(outputs: ["Prompt verification summary."])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )

        await engine.enqueueChildTranscript("Alpha-1 reports contact on east ridge.", from: "alpha-1")
        _ = await engine.emittedCompactions()

        let invocations = await summarizer.invocations()
        let invocation = try XCTUnwrap(invocations.first)
        let prompt = invocation.systemPrompt.lowercased()
        XCTAssertTrue(prompt.contains("preserve"))
        XCTAssertTrue(prompt.contains("location"))
        XCTAssertTrue(prompt.contains("threat"))
        XCTAssertTrue(prompt.contains("status"))
        XCTAssertTrue(prompt.contains("remove filler"))
        XCTAssertTrue(prompt.contains("under 30 words"))
    }

    func testCompactionEngineEmittedCompactionRoutesOnlyToParent() async throws {
        let tree = makeFixtureTree()
        let summarizer = MockTacticalSummarizer(outputs: ["Alpha contact summary for parent."])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "alpha-lead",
            tree: tree,
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )
        let router = MessageRouter()

        await engine.enqueueChildTranscript("Alpha-1 reports contact east.", from: "alpha-1")
        let emissions = await engine.emittedCompactions()
        let message = try XCTUnwrap(emissions.first?.message)

        XCTAssertTrue(router.shouldDisplay(message, for: "root", in: tree))
        XCTAssertFalse(router.shouldDisplay(message, for: "alpha-1", in: tree))
        XCTAssertFalse(router.shouldDisplay(message, for: "alpha-2", in: tree))
        XCTAssertFalse(router.shouldDisplay(message, for: "bravo", in: tree))
        XCTAssertFalse(router.shouldDisplay(message, for: "charlie-1", in: tree))
    }

    func testCompactionEngineRootProducesSitrepFromL1CompactionsOnly() async throws {
        let tree = makeFixtureTree()
        let summarizer = MockTacticalSummarizer(outputs: ["Sitrep: contact east, one casualty, alpha holding, bravo securing route."])
        let engine = makeCompactionEngine(
            localNodeID: "root",
            localDeviceID: "root-device",
            localRole: "commander",
            tree: tree,
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 2, defaultTTL: 8)
        )

        await engine.enqueueL1CompactionSummary("Should ignore non-L1 source.", from: "alpha-1")
        let ignoredSitrep = await engine.latestSITREP()
        XCTAssertNil(ignoredSitrep)

        await engine.enqueueL1CompactionSummary("Alpha engagement east, one injured, status holding.", from: "alpha")
        await engine.enqueueL1CompactionSummary("Bravo route secure, status green and moving.", from: "bravo")

        let latestSitrep = await engine.latestSITREP()
        let sitrep = try XCTUnwrap(latestSitrep)
        XCTAssertEqual(sitrep.triggerReason, .messageCount)
        XCTAssertEqual(sitrep.sourceMessageCount, 2)
        XCTAssertFalse(sitrep.text.isEmpty)
        let rootEmissions = await engine.emittedCompactions()
        XCTAssertTrue(rootEmissions.isEmpty, "Root should produce SITREP, not upward compaction messages")
    }

    // VAL-CROSS-001
    @MainActor
    func testCrossAreaFirstTimeJourneyDownloadInitJoinPTTAndTranscriptDeliveryWithinFiveSeconds() async throws {
        let startedAt = Date()

        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let downloadService = makeModelDownloadService(
            sandbox: sandbox,
            downloader: MockURLSessionDownloadClient(
                scriptedResponses: [
                    .init(
                        progressEvents: [(100, 1_000), (500, 1_000), (1_000, 1_000)],
                        result: .success(temporaryModelFile)
                    )
                ]
            ),
            availableStorageBytes: 20_000_000_000
        )

        _ = try await downloadService.ensureModelAvailable()
        let initializer = CactusModelInitializationService(
            downloadService: downloadService,
            initFunction: { _, _, _ in
                UnsafeMutableRawPointer(bitPattern: 0xBEEF)!
            },
            destroyFunction: { _ in }
        )
        _ = try await initializer.initializeModel()

        let organiserPeerID = UUID(uuidString: "10101010-0000-0000-0000-000000000001")!
        let networkID = UUID(uuidString: "10101010-0000-0000-0000-000000000002")!

        let organiserTransport = MockBluetoothMeshTransport()
        let organiserMesh = BluetoothMeshService(
            transport: organiserTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let organiserSync = TreeSyncService(meshService: organiserMesh)

        var publishedConfig = NetworkConfig(
            networkName: "Cross First Time",
            networkID: networkID,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        publishedConfig = organiserSync.secureConfigForPublishing(publishedConfig)
        organiserSync.setLocalConfig(publishedConfig)

        let participantTransport = MockBluetoothMeshTransport()
        participantTransport.setTreeConfig(publishedConfig, for: organiserPeerID)
        let participantMesh = BluetoothMeshService(
            transport: participantTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let participantSync = TreeSyncService(meshService: participantMesh)

        let discoveredNetwork = DiscoveredNetwork(
            peerID: organiserPeerID,
            networkID: networkID,
            networkName: "Cross First Time",
            openSlotCount: publishedConfig.openSlotCount,
            requiresPIN: false
        )
        let joinedConfig = try await participantSync.join(network: discoveredNetwork, pin: nil)
        XCTAssertEqual(joinedConfig.networkID, networkID)

        var routedConfig = joinedConfig
        _ = mutateClaim(nodeID: "alpha", claimedBy: "local-device", in: &routedConfig.tree)
        _ = mutateClaim(nodeID: "bravo", claimedBy: "peer-device", in: &routedConfig.tree)

        let senderTransport = MockBluetoothMeshTransport()
        let senderMesh = BluetoothMeshService(
            transport: senderTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let senderSync = TreeSyncService(meshService: senderMesh)
        senderSync.setLocalConfig(routedConfig)
        let senderRoleService = RoleClaimService(
            meshService: senderMesh,
            treeSyncService: senderSync,
            localDeviceID: "local-device",
            disconnectTimeout: 60
        )
        let senderAudio = AudioService(
            capturer: MockAudioCapturer(clips: [makeAlternatingPCMClip(sampleCount: 360, amplitude: 1_200)]),
            transcriber: MockCactusTranscriber(
                results: ["Alpha says contact east"],
                delayNanoseconds: 80_000_000
            ),
            maxRecordingDuration: 60
        )
        let senderMainViewModel = MainViewModel(
            meshService: senderMesh,
            roleClaimService: senderRoleService,
            localDeviceID: "local-device",
            audioService: senderAudio
        )

        let receiverMesh = BluetoothMeshService(
            transport: MockBluetoothMeshTransport(),
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let receiverSync = TreeSyncService(meshService: receiverMesh)
        receiverSync.setLocalConfig(routedConfig)
        let receiverRoleService = RoleClaimService(
            meshService: receiverMesh,
            treeSyncService: receiverSync,
            localDeviceID: "peer-device",
            disconnectTimeout: 60
        )
        let receiverMainViewModel = MainViewModel(
            meshService: receiverMesh,
            roleClaimService: receiverRoleService,
            localDeviceID: "peer-device",
            audioService: AudioService(
                capturer: MockAudioCapturer(clips: []),
                transcriber: MockCactusTranscriber(results: []),
                maxRecordingDuration: 60
            )
        )

        let connectedPeerID = UUID(uuidString: "10101010-0000-0000-0000-000000000099")!
        senderTransport.emit(.connectionStateChanged(connectedPeerID, .connected))
        senderMainViewModel.handlePeerConnectionStateChanged(peerID: connectedPeerID, state: .connected)

        await senderMainViewModel.startPushToTalk()
        await senderMainViewModel.stopPushToTalk()

        let outboundPacket = try XCTUnwrap(senderTransport.sentPackets.first)
        let outboundMessage = try decodeMessage(from: outboundPacket.data)
        receiverMainViewModel.handleIncomingMessage(outboundMessage)

        XCTAssertEqual(receiverMainViewModel.feedEntries.count, 1)
        XCTAssertEqual(receiverMainViewModel.feedEntries.first?.text, "Alpha says contact east")
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(startedAt), 5.0)
    }

    // VAL-CROSS-002
    func testCrossAreaFullCommunicationCycleLeafToRootSitrepAndNoGrandparentRawLeak() async throws {
        let tree = makeFixtureTree()
        let router = MessageRouter()
        let leafBroadcast = router.makeBroadcastMessage(
            transcript: "Alpha-1 contact at ridge line.",
            senderID: "alpha-1-device",
            senderNodeID: "alpha-1",
            senderRole: "Alpha 1",
            in: tree
        )

        XCTAssertTrue(router.shouldDisplay(leafBroadcast, for: "alpha", in: tree))
        XCTAssertTrue(router.shouldDisplay(leafBroadcast, for: "alpha-2", in: tree))
        XCTAssertFalse(router.shouldDisplay(leafBroadcast, for: "root", in: tree))

        let parentEngine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "Alpha Lead",
            tree: tree,
            summarizer: MockTacticalSummarizer(outputs: ["Alpha summary: contact at ridge, team holding."]),
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )
        await parentEngine.enqueueChildTranscript(
            leafBroadcast.payload.transcript ?? "",
            from: "alpha-1"
        )
        let parentCompactions = await parentEngine.emittedCompactions()
        let parentCompaction = try XCTUnwrap(parentCompactions.first)
        XCTAssertEqual(parentCompaction.message.type, .compaction)
        XCTAssertEqual(parentCompaction.message.parentID, "root")

        let rootEngine = makeCompactionEngine(
            localNodeID: "root",
            localDeviceID: "root-device",
            localRole: "Commander",
            tree: tree,
            summarizer: MockTacticalSummarizer(outputs: ["SITREP: Alpha contact ridge, holding position."]),
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )
        await rootEngine.enqueueL1CompactionSummary(
            parentCompaction.message.payload.summary ?? "",
            from: "alpha"
        )
        let rootSitrep = await rootEngine.latestSITREP()
        let sitrep = try XCTUnwrap(rootSitrep)
        XCTAssertFalse(sitrep.text.isEmpty)
    }

    // VAL-CROSS-003
    @MainActor
    func testCrossAreaTreeRestructureMidOperationReparentUpdatesRouting() throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(
            transport: transport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let treeSyncService = TreeSyncService(meshService: meshService)

        var config = NetworkConfig(
            networkName: "Cross Reparent",
            networkID: UUID(uuidString: "30303030-0000-0000-0000-000000000001")!,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        _ = mutateClaim(nodeID: "alpha-1", claimedBy: "alpha-1-device", in: &config.tree)
        treeSyncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSyncService,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )
        XCTAssertTrue(roleService.moveNode(nodeID: "alpha-1", newParentID: "bravo"))

        let updatedTree = try XCTUnwrap(treeSyncService.localConfig?.tree)
        let router = MessageRouter()
        let postMoveBroadcast = router.makeBroadcastMessage(
            transcript: "Routed after reparent.",
            senderID: "alpha-1-device",
            senderNodeID: "alpha-1",
            senderRole: "Alpha 1",
            in: updatedTree
        )

        XCTAssertEqual(postMoveBroadcast.parentID, "bravo")
        XCTAssertTrue(router.shouldDisplay(postMoveBroadcast, for: "bravo", in: updatedTree))
        XCTAssertFalse(router.shouldDisplay(postMoveBroadcast, for: "alpha", in: updatedTree))
    }

    // VAL-CROSS-004
    @MainActor
    func testCrossAreaNodeFailureRecoveryAutoReparentResumesCompactionRouting() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(
            transport: transport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let treeSyncService = TreeSyncService(meshService: meshService, disconnectTimeout: 0.05)

        let forwardingPeer = UUID(uuidString: "40404040-0000-0000-0000-000000000001")!
        let rootPeer = UUID(uuidString: "40404040-0000-0000-0000-000000000002")!
        let alphaPeer = UUID(uuidString: "40404040-0000-0000-0000-000000000003")!
        let bravoPeer = UUID(uuidString: "40404040-0000-0000-0000-000000000004")!
        let charliePeer = UUID(uuidString: "40404040-0000-0000-0000-000000000005")!

        [forwardingPeer, rootPeer, alphaPeer, bravoPeer, charliePeer].forEach {
            transport.emit(.connectionStateChanged($0, .connected))
        }

        let config = makeAutoReparentNetworkConfig(
            networkID: UUID(uuidString: "40404040-0000-0000-0000-000000000006")!,
            version: 50,
            rootOwnerID: rootPeer.uuidString,
            alphaOwnerID: alphaPeer.uuidString,
            bravoOwnerID: bravoPeer.uuidString,
            charlieOwnerID: charliePeer.uuidString
        )
        treeSyncService.setLocalConfig(config)

        transport.emit(.connectionStateChanged(bravoPeer, .disconnected))
        treeSyncService.handlePeerStateChange(peerID: bravoPeer, state: .disconnected)
        try await Task.sleep(nanoseconds: 250_000_000)

        let updatedTree = try XCTUnwrap(treeSyncService.localConfig?.tree)
        XCTAssertEqual(TreeHelpers.parent(of: "charlie", in: updatedTree)?.id, "alpha")

        let routedMessage = MessageRouter().makeCompactionMessage(
            summary: "Charlie resumed reporting after failover.",
            senderID: "charlie-device",
            senderNodeID: "charlie",
            senderRole: "Charlie",
            in: updatedTree
        )
        XCTAssertEqual(routedMessage.parentID, "alpha")
    }

    // VAL-CROSS-005
    @MainActor
    func testCrossAreaOrganiserHandoverAllowsNewOrganiserEditAndPropagation() throws {
        let oldTransport = MockBluetoothMeshTransport()
        let oldMesh = BluetoothMeshService(
            transport: oldTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let oldSync = TreeSyncService(meshService: oldMesh)
        let forwardingPeer = UUID(uuidString: "50505050-0000-0000-0000-000000000001")!
        oldTransport.emit(.connectionStateChanged(forwardingPeer, .connected))

        var config = NetworkConfig(
            networkName: "Cross Handover",
            networkID: UUID(uuidString: "50505050-0000-0000-0000-000000000002")!,
            createdBy: "old-organiser-device",
            pinHash: nil,
            version: 5,
            tree: makeFixtureTree()
        )
        _ = mutateClaim(nodeID: "alpha", claimedBy: "new-organiser-device", in: &config.tree)
        oldSync.setLocalConfig(config)

        let oldRoleService = RoleClaimService(
            meshService: oldMesh,
            treeSyncService: oldSync,
            localDeviceID: "old-organiser-device",
            disconnectTimeout: 60
        )
        XCTAssertTrue(oldRoleService.promote(nodeID: "alpha"))

        let promoteMessage = try XCTUnwrap(
            oldTransport.sentPackets
                .compactMap { try? decodeMessage(from: $0.data) }
                .first(where: { $0.type == .promote })
        )

        let newTransport = MockBluetoothMeshTransport()
        let newMesh = BluetoothMeshService(
            transport: newTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let newSync = TreeSyncService(meshService: newMesh)
        let propagationPeer = UUID(uuidString: "50505050-0000-0000-0000-000000000003")!
        newTransport.emit(.connectionStateChanged(propagationPeer, .connected))
        newSync.setLocalConfig(config)
        let newRoleService = RoleClaimService(
            meshService: newMesh,
            treeSyncService: newSync,
            localDeviceID: "new-organiser-device",
            disconnectTimeout: 60
        )

        newRoleService.handleIncomingMessage(promoteMessage)
        XCTAssertTrue(newRoleService.isOrganiser)
        XCTAssertTrue(newRoleService.renameNode(nodeID: "alpha", newLabel: "Alpha Command"))

        let propagatedUpdate = try XCTUnwrap(
            newTransport.sentPackets
                .compactMap { try? decodeMessage(from: $0.data) }
                .first(where: { $0.type == .treeUpdate })
        )
        oldRoleService.handleIncomingMessage(propagatedUpdate)

        let oldTree = try XCTUnwrap(oldSync.localConfig?.tree)
        XCTAssertEqual(findNode(nodeID: "alpha", in: oldTree)?.label, "Alpha Command")
    }

    // VAL-CROSS-006
    @MainActor
    func testCrossAreaAfterActionReviewSearchReturnsBroadcastAndCompactionWithMetadata() {
        let store = InMemoryAfterActionReviewStore()
        let viewModel = AfterActionReviewViewModel(store: store)

        viewModel.record(
            Message.make(
                type: .broadcast,
                senderID: "leaf-device",
                senderRole: "Leaf",
                parentID: "alpha",
                treeLevel: 2,
                ttl: 4,
                encrypted: false,
                latitude: 34.001,
                longitude: -117.001,
                accuracy: 3.1,
                transcript: "Casualty reported near checkpoint."
            )
        )
        viewModel.record(
            Message.make(
                type: .compaction,
                senderID: "alpha-device",
                senderRole: "Alpha Lead",
                parentID: "root",
                treeLevel: 1,
                ttl: 4,
                encrypted: false,
                latitude: 34.002,
                longitude: -117.002,
                accuracy: 4.2,
                summary: "Casualty stabilized and extraction requested."
            )
        )

        viewModel.query = "casualty"
        XCTAssertEqual(viewModel.results.count, 2)
        XCTAssertEqual(Set(viewModel.results.map(\.type)), [.broadcast, .compaction])
        XCTAssertTrue(viewModel.results.allSatisfy { !$0.senderRole.isEmpty })
        XCTAssertTrue(viewModel.results.allSatisfy { $0.timestamp.timeIntervalSince1970 > 0 })
    }

    // VAL-CROSS-007
    func testCrossAreaDemoScenarioSection14CompletesWithinTwoMinutes() async throws {
        let start = Date()
        let tree = makeFixtureTree()

        let alphaEngine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "Alpha Lead",
            tree: tree,
            summarizer: MockTacticalSummarizer(outputs: ["Alpha compaction: contact east, one casualty."]),
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )
        let charlieEngine = makeCompactionEngine(
            localNodeID: "charlie",
            localDeviceID: "charlie-device",
            localRole: "Charlie Lead",
            tree: tree,
            summarizer: MockTacticalSummarizer(outputs: ["Charlie compaction: route secure, moving north."]),
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )
        let rootEngine = makeCompactionEngine(
            localNodeID: "root",
            localDeviceID: "root-device",
            localRole: "Commander",
            tree: tree,
            summarizer: MockTacticalSummarizer(outputs: ["SITREP: Alpha contact/casualty, Bravo route secure."]),
            configuration: .init(timeWindow: 30, messageCountThreshold: 2, defaultTTL: 8)
        )

        await alphaEngine.enqueueChildTranscript("Alpha-1: contact and casualty at east ridge.", from: "alpha-1")
        await charlieEngine.enqueueChildTranscript("Charlie-1: route secure, advancing.", from: "charlie-1")

        let alphaCompactions = await alphaEngine.emittedCompactions()
        let charlieCompactions = await charlieEngine.emittedCompactions()
        let alphaCompaction = try XCTUnwrap(alphaCompactions.first)
        let charlieCompaction = try XCTUnwrap(charlieCompactions.first)

        await rootEngine.enqueueL1CompactionSummary(alphaCompaction.outputText, from: "alpha")
        await rootEngine.enqueueL1CompactionSummary(charlieCompaction.outputText, from: "charlie")
        let rootSitrep = await rootEngine.latestSITREP()
        let sitrep = try XCTUnwrap(rootSitrep)
        XCTAssertFalse(sitrep.text.isEmpty)

        XCTAssertLessThanOrEqual(Date().timeIntervalSince(start), 120.0)
    }

    // VAL-CROSS-008
    @MainActor
    func testCrossAreaEncryptedCommunicationLateJoinerCanDecryptMessages() async throws {
        let organiserTransport = MockBluetoothMeshTransport()
        let organiserMesh = BluetoothMeshService(
            transport: organiserTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let organiserSync = TreeSyncService(meshService: organiserMesh)

        let networkID = UUID(uuidString: "80808080-0000-0000-0000-000000000001")!
        var securedConfig = NetworkConfig(
            networkName: "Encrypted Cross",
            networkID: networkID,
            createdBy: "organiser-device",
            pinHash: NetworkConfig.hashPIN("1234"),
            version: 1,
            tree: makeFixtureTree()
        )
        securedConfig = organiserSync.secureConfigForPublishing(securedConfig)
        organiserSync.setLocalConfig(securedConfig)

        let organiserPeerID = UUID(uuidString: "80808080-0000-0000-0000-000000000002")!
        let lateJoinerPeerID = UUID(uuidString: "80808080-0000-0000-0000-000000000003")!

        let lateTransport = MockBluetoothMeshTransport()
        lateTransport.setTreeConfig(securedConfig, for: organiserPeerID)
        let lateMesh = BluetoothMeshService(
            transport: lateTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let lateSync = TreeSyncService(meshService: lateMesh)

        let discovered = DiscoveredNetwork(
            peerID: organiserPeerID,
            networkID: networkID,
            networkName: securedConfig.networkName,
            openSlotCount: securedConfig.openSlotCount,
            requiresPIN: true
        )
        _ = try await lateSync.join(network: discovered, pin: "1234")

        organiserTransport.emit(.connectionStateChanged(lateJoinerPeerID, .connected))

        let receivedByLateJoiner = LockedArray<Message>()
        lateMesh.onMessageReceived = { receivedByLateJoiner.append($0) }

        let plaintextTranscript = "encrypted contact report"
        let outbound = Message.make(
            type: .broadcast,
            senderID: "organiser-device",
            senderRole: "organiser",
            parentID: "root",
            treeLevel: 1,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: plaintextTranscript
        )
        organiserMesh.publish(outbound)

        let encryptedPacket = try XCTUnwrap(organiserTransport.sentPackets.first)
        XCTAssertNil(encryptedPacket.data.range(of: Data(plaintextTranscript.utf8)))

        lateTransport.emit(.receivedData(encryptedPacket.data, from: organiserPeerID))

        let didDecrypt = await waitForCondition(timeout: 1.0) {
            receivedByLateJoiner.values.last?.payload.transcript == plaintextTranscript
        }
        XCTAssertTrue(didDecrypt)
        XCTAssertEqual(receivedByLateJoiner.values.last?.payload.encrypted, true)
    }

    // VAL-CROSS-009
    func testCrossAreaPriorityEscalationEndToEndBypassesNormalCycle() async throws {
        let tree = makeFixtureTree()
        let parentEngine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "Alpha Lead",
            tree: tree,
            summarizer: MockTacticalSummarizer(outputs: ["Casualty at grid five; immediate medevac."]),
            configuration: .init(timeWindow: 30, messageCountThreshold: 10, defaultTTL: 8)
        )
        await parentEngine.enqueueChildTranscript("Alpha-1 reports CASUALTY at grid five.", from: "alpha-1")
        let parentEmissions = await parentEngine.emittedCompactions()
        let parentEmission = try XCTUnwrap(parentEmissions.first)
        XCTAssertEqual(parentEmission.triggerReason, .priorityKeyword)

        let rootEngine = makeCompactionEngine(
            localNodeID: "root",
            localDeviceID: "root-device",
            localRole: "Commander",
            tree: tree,
            summarizer: MockTacticalSummarizer(outputs: ["SITREP priority: casualty at grid five."]),
            configuration: .init(timeWindow: 30, messageCountThreshold: 10, defaultTTL: 8)
        )
        await rootEngine.enqueueL1CompactionSummary(parentEmission.outputText, from: "alpha")
        let rootSitrep = await rootEngine.latestSITREP()
        let sitrep = try XCTUnwrap(rootSitrep)
        XCTAssertEqual(sitrep.triggerReason, .priorityKeyword)

        let normalRootEngine = makeCompactionEngine(
            localNodeID: "root",
            localDeviceID: "root-device",
            localRole: "Commander",
            tree: tree,
            summarizer: MockTacticalSummarizer(outputs: ["Normal sitrep"]),
            configuration: .init(timeWindow: 30, messageCountThreshold: 2, defaultTTL: 8)
        )
        await normalRootEngine.enqueueL1CompactionSummary("Routine status update.", from: "alpha")
        let normalSitrep = await normalRootEngine.latestSITREP()
        XCTAssertNil(normalSitrep)
    }

    // VAL-CROSS-010
    @MainActor
    func testCrossAreaDataFlowTransparencyDuringActiveCommunication() async throws {
        let viewModel = DataFlowViewModel()
        let summarizer = MockTacticalSummarizer(outputs: ["Compacted output for data flow visibility."])
        let engine = makeCompactionEngine(
            localNodeID: "alpha",
            localDeviceID: "alpha-device",
            localRole: "Alpha Lead",
            tree: makeFixtureTree(),
            summarizer: summarizer,
            configuration: .init(timeWindow: 30, messageCountThreshold: 1, defaultTTL: 8)
        )

        await engine.setProcessingObserver { metrics in
            Task { @MainActor in
                viewModel.handleProcessingMetrics(metrics)
            }
        }
        await engine.setCompactionEmissionObserver { emission in
            Task { @MainActor in
                viewModel.handleOutgoingCompaction(emission)
            }
        }

        let incoming = Message.make(
            type: .broadcast,
            senderID: "alpha-1-device",
            senderRole: "Alpha 1",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Routine update at checkpoint"
        )
        viewModel.handleIncomingMessage(incoming)

        await engine.enqueueChildTranscript("Routine update at checkpoint", from: "alpha-1")
        let outgoingObserved = await waitForCondition(timeout: 1.0) {
            await MainActor.run {
                !viewModel.outgoingEntries.isEmpty
            }
        }
        XCTAssertTrue(outgoingObserved)
        XCTAssertFalse(viewModel.incomingEntries.isEmpty)
        XCTAssertEqual(viewModel.processing.triggerReason, .messageCount)
    }

    // VAL-CROSS-011
    @MainActor
    func testCrossAreaConcurrentRoleClaimConflictOrganiserWinsAndPeersConverge() throws {
        let organiserTransport = MockBluetoothMeshTransport()
        let organiserMesh = BluetoothMeshService(
            transport: organiserTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let organiserSync = TreeSyncService(meshService: organiserMesh)
        let forwardingPeer = UUID(uuidString: "B1111111-0000-0000-0000-000000000001")!
        organiserTransport.emit(.connectionStateChanged(forwardingPeer, .connected))

        let participantTransport = MockBluetoothMeshTransport()
        let participantMesh = BluetoothMeshService(
            transport: participantTransport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let participantSync = TreeSyncService(meshService: participantMesh)
        participantTransport.emit(.connectionStateChanged(forwardingPeer, .connected))

        var config = NetworkConfig(
            networkName: "Claim Conflict",
            networkID: UUID(uuidString: "B1111111-0000-0000-0000-000000000002")!,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        _ = mutateClaim(nodeID: "alpha", claimedBy: nil, in: &config.tree)
        organiserSync.setLocalConfig(config)
        participantSync.setLocalConfig(config)

        let organiserRoleService = RoleClaimService(
            meshService: organiserMesh,
            treeSyncService: organiserSync,
            localDeviceID: "organiser-device",
            disconnectTimeout: 60
        )
        let participantRoleService = RoleClaimService(
            meshService: participantMesh,
            treeSyncService: participantSync,
            localDeviceID: "participant-device",
            disconnectTimeout: 60
        )

        XCTAssertEqual(participantRoleService.claim(nodeID: "alpha"), .claimed(nodeID: "alpha"))
        let participantClaimMessage = try XCTUnwrap(
            participantTransport.sentPackets
                .compactMap { try? decodeMessage(from: $0.data) }
                .first(where: { $0.type == .claim })
        )
        organiserRoleService.handleIncomingMessage(participantClaimMessage)

        XCTAssertEqual(organiserRoleService.claim(nodeID: "alpha"), .claimed(nodeID: "alpha"))
        let organiserClaimMessage = try XCTUnwrap(
            organiserTransport.sentPackets
                .compactMap { try? decodeMessage(from: $0.data) }
                .first(where: { $0.type == .claim })
        )
        let rejectionMessage = try XCTUnwrap(
            organiserTransport.sentPackets
                .compactMap { try? decodeMessage(from: $0.data) }
                .first(where: { $0.type == .claimRejected })
        )

        participantRoleService.handleIncomingMessage(organiserClaimMessage)
        participantRoleService.handleIncomingMessage(rejectionMessage)

        XCTAssertEqual(participantRoleService.lastClaimRejection, .organiserWins)
        XCTAssertNil(participantRoleService.activeClaimNodeID)
        XCTAssertEqual(claimedByValue(nodeID: "alpha", in: organiserSync.localConfig), "organiser-device")
        XCTAssertEqual(claimedByValue(nodeID: "alpha", in: participantSync.localConfig), "organiser-device")
    }

    // VAL-CROSS-012
    func testCrossAreaModelDownloadInterruptionRecoveryThenCactusInitSucceeds() async throws {
        let sandbox = try makeModelDownloadSandbox()
        defer { sandbox.cleanup() }

        let resumeData = Data("cross-area-resume-point".utf8)
        let temporaryModelFile = try makeTemporaryModelFile(in: sandbox.baseDirectory)
        let downloader = MockURLSessionDownloadClient(
            scriptedResponses: [
                .init(
                    progressEvents: [(300, 1_000)],
                    result: .failure(URLSessionDownloadClientError.interrupted(resumeData: resumeData))
                ),
                .init(
                    progressEvents: [(900, 1_000), (1_000, 1_000)],
                    result: .success(temporaryModelFile)
                )
            ]
        )
        let service = makeModelDownloadService(
            sandbox: sandbox,
            downloader: downloader,
            availableStorageBytes: 20_000_000_000
        )

        do {
            _ = try await service.ensureModelAvailable()
            XCTFail("Expected interruption on first download attempt")
        } catch let error as ModelDownloadServiceError {
            guard case let .interrupted(canResume) = error else {
                return XCTFail("Expected interrupted error, got \(error)")
            }
            XCTAssertTrue(canResume)
        }

        _ = try await service.ensureModelAvailable()
        let initializer = CactusModelInitializationService(
            downloadService: service,
            initFunction: { _, _, _ in
                UnsafeMutableRawPointer(bitPattern: 0xCAFEBABE)!
            },
            destroyFunction: { _ in }
        )
        let modelHandle = try await initializer.initializeModel()
        XCTAssertEqual(modelHandle, UnsafeMutableRawPointer(bitPattern: 0xCAFEBABE))
    }

    // VAL-CROSS-013
    @MainActor
    func testCrossAreaBackgroundingFlushesCompactionQueueAndForegroundRestartsMesh() async throws {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(
            transport: transport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let peerID = UUID(uuidString: "D1313131-0000-0000-0000-000000000001")!
        transport.emit(.connectionStateChanged(peerID, .connected))

        let summarizer = MockTacticalSummarizer(outputs: ["Background flush summary"])
        let coordinator = AppNetworkCoordinator(
            meshService: meshService,
            localDeviceID: "alpha-device",
            mainAudioService: AudioService(
                capturer: MockAudioCapturer(clips: []),
                transcriber: MockCactusTranscriber(results: []),
                maxRecordingDuration: 60
            ),
            compactionEngineFactory: { localDeviceID, localNodeID, localSenderRole, initialTree, messageRouter in
                CompactionEngine(
                    localDeviceID: localDeviceID,
                    localNodeID: localNodeID,
                    localSenderRole: localSenderRole,
                    initialTree: initialTree,
                    messageRouter: messageRouter,
                    summarizer: summarizer,
                    configuration: .init(timeWindow: 30, messageCountThreshold: 5, defaultTTL: 8)
                )
            }
        )

        var config = NetworkConfig(
            networkName: "Background Integration",
            networkID: UUID(uuidString: "D1313131-0000-0000-0000-000000000002")!,
            createdBy: "organiser-device",
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        _ = mutateClaim(nodeID: "alpha", claimedBy: "alpha-device", in: &config.tree)
        _ = mutateClaim(nodeID: "alpha-1", claimedBy: "alpha-1-device", in: &config.tree)
        coordinator.treeSyncService.setLocalConfig(config)

        let roleReady = await waitForCondition(timeout: 1.0) {
            await MainActor.run {
                coordinator.roleClaimService.activeClaimNodeID == "alpha"
            }
        }
        XCTAssertTrue(roleReady)

        let inboundBroadcast = Message.make(
            type: .broadcast,
            senderID: "alpha-1",
            senderRole: "Alpha 1",
            parentID: "alpha",
            treeLevel: 2,
            ttl: 4,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            transcript: "Contact while app backgrounds."
        )
        let inboundData = try JSONEncoder().encode(inboundBroadcast)
        transport.emit(.receivedData(inboundData, from: peerID))

        XCTAssertTrue(transport.sentPackets.isEmpty, "Compaction should remain queued before background flush.")

        coordinator.handleScenePhase(.background)

        let flushedCompactionPublished = await waitForCondition(timeout: 1.0) { [self] in
            transport.sentPackets.contains { packet in
                (try? self.decodeMessage(from: packet.data).type) == .compaction
            }
        }
        XCTAssertTrue(flushedCompactionPublished)

        transport.emit(.connectionStateChanged(peerID, .disconnected))
        coordinator.handleScenePhase(.active)
        transport.emit(.connectionStateChanged(peerID, .connected))

        XCTAssertGreaterThanOrEqual(transport.startCallCount, 1)
        let pttReenabled = await waitForCondition(timeout: 1.0) {
            await MainActor.run {
                !coordinator.mainViewModel.isPTTDisabled
            }
        }
        XCTAssertTrue(pttReenabled)
        XCTAssertGreaterThanOrEqual(coordinator.afterActionReviewViewModel.totalMessageCount, 2)
    }

    // VAL-CROSS-014
    @MainActor
    func testCrossAreaGPSCoordinatesPreservedFromBroadcastToCompactionAndPersistence() {
        let expectedLatitude = 37.3349
        let expectedLongitude = -122.0090
        let expectedAccuracy = 2.5
        let router = MessageRouter(
            gpsProvider: {
                .init(
                    latitude: expectedLatitude,
                    longitude: expectedLongitude,
                    accuracy: expectedAccuracy
                )
            }
        )
        let tree = makeFixtureTree()
        let store = InMemoryAfterActionReviewStore()

        let broadcast = router.makeBroadcastMessage(
            transcript: "Leaf reports contact at checkpoint.",
            senderID: "alpha-1-device",
            senderNodeID: "alpha-1",
            senderRole: "Alpha 1",
            in: tree
        )
        let compaction = router.makeCompactionMessage(
            summary: "Alpha summary with checkpoint contact.",
            senderID: "alpha-device",
            senderNodeID: "alpha",
            senderRole: "Alpha Lead",
            in: tree
        )

        store.persist(broadcast)
        store.persist(compaction)

        let persisted = store.search(query: "checkpoint")
        XCTAssertEqual(persisted.count, 2)
        XCTAssertTrue(
            persisted.allSatisfy {
                abs($0.latitude - expectedLatitude) < 0.000_001 &&
                    abs($0.longitude - expectedLongitude) < 0.000_001 &&
                    abs($0.accuracy - expectedAccuracy) < 0.000_001 &&
                    !$0.isFallbackLocation
            }
        )
    }

    private func makeCompactionEngine(
        localNodeID: String,
        localDeviceID: String,
        localRole: String,
        tree: TreeNode,
        summarizer: any TacticalSummarizing,
        configuration: CompactionEngine.Configuration
    ) -> CompactionEngine {
        CompactionEngine(
            localDeviceID: localDeviceID,
            localNodeID: localNodeID,
            localSenderRole: localRole,
            initialTree: tree,
            summarizer: summarizer,
            configuration: configuration
        )
    }

    private func waitForCondition(
        timeout: TimeInterval,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }

    private func makePCMClip(
        samples: [Int16],
        sampleRate: Int = 16_000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> RecordedAudioClip {
        var data = Data(count: samples.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { destination in
            samples.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        return RecordedAudioClip(
            data: data,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
    }

    private func makeAlternatingPCMClip(
        sampleCount: Int,
        amplitude: Int16,
        sampleRate: Int = 16_000
    ) -> RecordedAudioClip {
        var data = Data(count: sampleCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude
            }
        }
        return RecordedAudioClip(
            data: data,
            sampleRate: sampleRate,
            channels: 1,
            bitsPerSample: 16
        )
    }

    private func makeMeshMessage(
        id: UUID = UUID(),
        ttl: Int,
        type: Message.MessageType = .broadcast
    ) -> Message {
        Message.make(
            id: id,
            type: type,
            senderID: "node-alpha",
            senderRole: "leaf",
            parentID: "node-parent",
            treeLevel: 2,
            ttl: ttl,
            encrypted: false,
            latitude: 10.0,
            longitude: 20.0,
            accuracy: 3.0,
            transcript: "test-message"
        )
    }

    private func decodeMessage(from data: Data) throws -> Message {
        try JSONDecoder().decode(Message.self, from: data)
    }

    private func makeNetworkConfig(
        networkID: UUID,
        version: Int,
        rootLabel: String,
        pin: String? = nil
    ) -> NetworkConfig {
        NetworkConfig(
            networkName: "Net-\(version)",
            networkID: networkID,
            createdBy: "organiser",
            pinHash: NetworkConfig.hashPIN(pin),
            version: version,
            tree: TreeNode(
                id: "root",
                label: rootLabel,
                claimedBy: nil,
                children: [
                    TreeNode(id: "alpha", label: "Alpha", claimedBy: nil, children: []),
                    TreeNode(id: "bravo", label: "Bravo", claimedBy: "claimed-device", children: [])
                ]
            )
        )
    }

    private func makeAutoReparentNetworkConfig(
        networkID: UUID,
        version: Int,
        rootOwnerID: String,
        alphaOwnerID: String,
        bravoOwnerID: String,
        charlieOwnerID: String
    ) -> NetworkConfig {
        NetworkConfig(
            networkName: "Resilience Net",
            networkID: networkID,
            createdBy: rootOwnerID,
            pinHash: nil,
            version: version,
            tree: TreeNode(
                id: "root",
                label: "Root",
                claimedBy: rootOwnerID,
                children: [
                    TreeNode(
                        id: "alpha",
                        label: "Alpha",
                        claimedBy: alphaOwnerID,
                        children: [
                            TreeNode(
                                id: "bravo",
                                label: "Bravo",
                                claimedBy: bravoOwnerID,
                                children: [
                                    TreeNode(
                                        id: "charlie",
                                        label: "Charlie",
                                        claimedBy: charlieOwnerID,
                                        children: []
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        )
    }

    private func withClaim(nodeID: String, claimedBy: String?, in config: NetworkConfig) -> NetworkConfig {
        var updated = config
        _ = mutateClaim(nodeID: nodeID, claimedBy: claimedBy, in: &updated.tree)
        return updated
    }

    private func claimedByValue(nodeID: String, in config: NetworkConfig?) -> String? {
        guard let config else {
            return nil
        }
        return findNode(nodeID: nodeID, in: config.tree)?.claimedBy
    }

    @discardableResult
    private func mutateClaim(nodeID: String, claimedBy: String?, in tree: inout TreeNode) -> Bool {
        if tree.id == nodeID {
            tree.claimedBy = claimedBy
            return true
        }

        for index in tree.children.indices {
            if mutateClaim(nodeID: nodeID, claimedBy: claimedBy, in: &tree.children[index]) {
                return true
            }
        }
        return false
    }

    private func findNode(nodeID: String, in tree: TreeNode) -> TreeNode? {
        if tree.id == nodeID {
            return tree
        }

        for child in tree.children {
            if let found = findNode(nodeID: nodeID, in: child) {
                return found
            }
        }
        return nil
    }

    private func makeFixtureTree() -> TreeNode {
        TreeNode(
            id: "root",
            label: "Root",
            claimedBy: nil,
            children: [
                TreeNode(
                    id: "alpha",
                    label: "Alpha",
                    claimedBy: nil,
                    children: [
                        TreeNode(id: "alpha-1", label: "Alpha 1", claimedBy: nil, children: []),
                        TreeNode(id: "alpha-2", label: "Alpha 2", claimedBy: nil, children: [])
                    ]
                ),
                TreeNode(
                    id: "bravo",
                    label: "Bravo",
                    claimedBy: nil,
                    children: []
                ),
                TreeNode(
                    id: "charlie",
                    label: "Charlie",
                    claimedBy: nil,
                    children: [
                        TreeNode(id: "charlie-1", label: "Charlie 1", claimedBy: nil, children: [])
                    ]
                )
            ]
        )
    }

    private func deterministicUUID(from value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    @MainActor
    private func makeRoleClaimContextForSettings(
        localDeviceID: String,
        createdBy: String,
        claims: [String: String] = [:]
    ) -> (transport: MockBluetoothMeshTransport, syncService: TreeSyncService, roleService: RoleClaimService) {
        let transport = MockBluetoothMeshTransport()
        let meshService = BluetoothMeshService(
            transport: transport,
            deduplicator: MessageDeduplicator(capacity: 1_000)
        )
        let syncService = TreeSyncService(meshService: meshService)
        transport.emit(
            .connectionStateChanged(
                UUID(uuidString: "D0D0D0D0-0000-0000-0000-000000000001")!,
                .connected
            )
        )

        var config = NetworkConfig(
            networkName: "TacNet Settings",
            networkID: UUID(uuidString: "DEADBEEF-CAFE-BABE-FADE-000000000001")!,
            createdBy: createdBy,
            pinHash: nil,
            version: 1,
            tree: makeFixtureTree()
        )
        for (nodeID, ownerID) in claims {
            _ = mutateClaim(nodeID: nodeID, claimedBy: ownerID, in: &config.tree)
        }
        syncService.setLocalConfig(config)

        let roleService = RoleClaimService(
            meshService: meshService,
            treeSyncService: syncService,
            localDeviceID: localDeviceID,
            disconnectTimeout: 60
        )
        return (transport, syncService, roleService)
    }

    private func makeModelDownloadSandbox() throws -> ModelDownloadSandbox {
        let suiteName = "TacNetTests.ModelDownload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TacNetTests-\(UUID().uuidString)", isDirectory: true)
        let appSupportDirectory = baseDirectory.appendingPathComponent("ApplicationSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)

        return ModelDownloadSandbox(
            suiteName: suiteName,
            userDefaults: defaults,
            baseDirectory: baseDirectory,
            appSupportDirectory: appSupportDirectory
        )
    }

    private func makeTemporaryModelFile(in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent("mock-downloaded-model-\(UUID().uuidString).bin")
        try Data("mock-model-contents".utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func makeModelDownloadConfiguration(
        requiresZipArchive: Bool = false
    ) -> ModelDownloadConfiguration {
        // Tests default to `requiresZipArchive: false` because the existing
        // `MockURLSessionDownloadClient` emits tiny non-zip byte blobs as the
        // "downloaded" artifact. Production (`.live`) keeps the default `true`
        // so real HTTP error bodies never reach the sentinel path.
        ModelDownloadConfiguration(
            modelURL: URL(string: "https://huggingface.co/Cactus-Compute/gemma-4-e4b-int4/resolve/main/gemma-4-e4b-int4.bin")!,
            expectedModelSizeBytes: 6_700_000_000,
            modelDirectoryName: "gemma-4-e4b-int4",
            modelFileName: "gemma-4-e4b-int4.bin",
            requiresZipArchive: requiresZipArchive
        )
    }

    private func makeModelDownloadService(
        sandbox: ModelDownloadSandbox,
        downloader: URLSessionDownloading,
        availableStorageBytes: Int64,
        requiresZipArchive: Bool = false
    ) -> ModelDownloadService {
        ModelDownloadService(
            configuration: makeModelDownloadConfiguration(requiresZipArchive: requiresZipArchive),
            downloader: downloader,
            storageChecker: MockStorageChecker(availableBytes: availableStorageBytes),
            fileManager: FileManager.default,
            userDefaults: sandbox.userDefaults,
            applicationSupportDirectory: sandbox.appSupportDirectory,
            persistenceKeyPrefix: "TacNetTests.ModelDownload.\(UUID().uuidString)"
        )
    }
}

private final class MockBluetoothMeshTransport: BluetoothMeshTransporting {
    struct SentPacket {
        let data: Data
        let messageType: Message.MessageType
        let peerIDs: Set<UUID>
    }

    var eventHandler: ((BluetoothMeshTransportEvent) -> Void)?
    private(set) var sentPackets: [SentPacket] = []
    private var treeConfigByPeer: [UUID: Data] = [:]
    private(set) var lastConfiguredAdvertisement: NetworkAdvertisement?
    private(set) var configuredTreeConfigPayload: Data = Data()
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func send(_ data: Data, messageType: Message.MessageType, to peerIDs: Set<UUID>) {
        sentPackets.append(SentPacket(data: data, messageType: messageType, peerIDs: peerIDs))
    }

    func emit(_ event: BluetoothMeshTransportEvent) {
        eventHandler?(event)
    }

    func configureAdvertisement(_ summary: NetworkAdvertisement?) {
        lastConfiguredAdvertisement = summary
    }

    func updateTreeConfigPayload(_ data: Data) {
        configuredTreeConfigPayload = data
    }

    func requestTreeConfig(from peerID: UUID, completion: @escaping (Result<Data, Error>) -> Void) {
        if let payload = treeConfigByPeer[peerID] {
            completion(.success(payload))
            return
        }

        guard !configuredTreeConfigPayload.isEmpty else {
            completion(.failure(BluetoothMeshTransportError.treeConfigUnavailable))
            return
        }

        completion(.success(configuredTreeConfigPayload))
    }

    func setTreeConfig(_ networkConfig: NetworkConfig, for peerID: UUID) {
        treeConfigByPeer[peerID] = try? JSONEncoder().encode(networkConfig)
    }
}

private struct ModelDownloadSandbox {
    let suiteName: String
    let userDefaults: UserDefaults
    let baseDirectory: URL
    let appSupportDirectory: URL

    func cleanup() {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: baseDirectory)
    }
}

private struct MockStorageChecker: StorageChecking {
    let availableBytes: Int64

    func availableStorageBytes(for _: URL) throws -> Int64 {
        availableBytes
    }
}

private final class MockURLSessionDownloadClient: URLSessionDownloading, @unchecked Sendable {
    struct ScriptedResponse {
        let progressEvents: [(written: Int64, total: Int64)]
        let result: Result<URL, Error>
        let responseDelayNanoseconds: UInt64

        init(
            progressEvents: [(written: Int64, total: Int64)],
            result: Result<URL, Error>,
            responseDelayNanoseconds: UInt64 = 0
        ) {
            self.progressEvents = progressEvents
            self.result = result
            self.responseDelayNanoseconds = responseDelayNanoseconds
        }
    }

    private let lock = NSLock()
    private var requests: [ModelDownloadRequest] = []
    private var scriptedResponses: [ScriptedResponse]

    init(scriptedResponses: [ScriptedResponse]) {
        self.scriptedResponses = scriptedResponses
    }

    var requestCount: Int {
        lock.withLock {
            requests.count
        }
    }

    func request(at index: Int) -> ModelDownloadRequest? {
        lock.withLock {
            guard requests.indices.contains(index) else { return nil }
            return requests[index]
        }
    }

    func download(
        request: ModelDownloadRequest,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let response: ScriptedResponse = lock.withLock {
            requests.append(request)
            guard !scriptedResponses.isEmpty else {
                return ScriptedResponse(
                    progressEvents: [],
                    result: .failure(NSError(domain: "MockURLSessionDownloadClient", code: -1))
                )
            }
            return scriptedResponses.removeFirst()
        }

        response.progressEvents.forEach { progress($0.written, $0.total) }
        if response.responseDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: response.responseDelayNanoseconds)
        }

        switch response.result {
        case let .success(url):
            return url
        case let .failure(error):
            throw error
        }
    }
}

private actor MockAudioCapturer: AudioCapturing {
    private var clips: [RecordedAudioClip]
    private var isCapturing = false

    init(clips: [RecordedAudioClip]) {
        self.clips = clips
    }

    func startCapture() async throws {
        isCapturing = true
    }

    func stopCapture() async throws -> RecordedAudioClip {
        guard isCapturing else {
            throw AudioServiceError.notRecording
        }
        isCapturing = false
        guard !clips.isEmpty else {
            return RecordedAudioClip(data: Data(), sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        }
        return clips.removeFirst()
    }
}

private actor MockCactusTranscriber: CactusTranscribing {
    private var results: [String]
    private let delayNanoseconds: UInt64
    private var inputs: [Data] = []

    init(results: [String], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    func transcribePCM16kMono(_ pcmData: Data) async throws -> String {
        inputs.append(pcmData)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !results.isEmpty else {
            return ""
        }
        return results.removeFirst()
    }

    func receivedPCMInputs() -> [Data] {
        inputs
    }
}

private actor MockTranscriptConsumer: TranscriptConsuming {
    private var transcripts: [AudioService.TranscriptResult] = []

    func receiveTranscript(_ transcript: AudioService.TranscriptResult) async {
        transcripts.append(transcript)
    }

    func received() -> [AudioService.TranscriptResult] {
        transcripts
    }
}

private actor MockTacticalSummarizer: TacticalSummarizing {
    struct Invocation: Equatable, Sendable {
        let systemPrompt: String
        let userPrompt: String
    }

    private var outputs: [String]
    private let delayNanoseconds: UInt64
    private var recordedInvocations: [Invocation] = []

    init(outputs: [String], delayNanoseconds: UInt64 = 0) {
        self.outputs = outputs
        self.delayNanoseconds = delayNanoseconds
    }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> String {
        recordedInvocations.append(Invocation(systemPrompt: systemPrompt, userPrompt: userPrompt))
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if outputs.isEmpty {
            return userPrompt
        }
        return outputs.removeFirst()
    }

    func invocations() -> [Invocation] {
        recordedInvocations
    }
}

private final class CapturingSecurityLogger: SecurityEventLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func log(_ message: String) {
        lock.withLock {
            entries.append(message)
        }
    }

    var messages: [String] {
        lock.withLock {
            entries
        }
    }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    func append(_ element: Element) {
        lock.withLock {
            storage.append(element)
        }
    }

    var values: [Element] {
        lock.withLock {
            storage
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
