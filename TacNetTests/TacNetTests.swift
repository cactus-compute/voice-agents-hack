import XCTest
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

    private func makeModelDownloadConfiguration() -> ModelDownloadConfiguration {
        ModelDownloadConfiguration(
            modelURL: URL(string: "https://huggingface.co/Cactus-Compute/gemma-4-e4b-int4/resolve/main/gemma-4-e4b-int4.bin")!,
            expectedModelSizeBytes: 6_700_000_000,
            modelDirectoryName: "gemma-4-e4b-int4",
            modelFileName: "gemma-4-e4b-int4.bin"
        )
    }

    private func makeModelDownloadService(
        sandbox: ModelDownloadSandbox,
        downloader: URLSessionDownloading,
        availableStorageBytes: Int64
    ) -> ModelDownloadService {
        ModelDownloadService(
            configuration: makeModelDownloadConfiguration(),
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

    func start() {}

    func stop() {}

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

        switch response.result {
        case let .success(url):
            return url
        case let .failure(error):
            throw error
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
