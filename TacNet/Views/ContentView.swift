import SwiftUI

struct ContentView: View {
    @StateObject private var bootstrapViewModel = AppBootstrapViewModel()
    @StateObject private var treeBuilderViewModel = TreeBuilderViewModel(
        createdBy: ProcessInfo.processInfo.hostName
    )
    @StateObject private var appNetworkCoordinator = AppNetworkCoordinator()
    @State private var onboardingRoute: OnboardingRoute = .welcome

    private enum OnboardingRoute {
        case welcome
        case createNetwork
        case joinNetwork
        case roleSelection
        case main
    }

    var body: some View {
        Group {
            if bootstrapViewModel.isDownloadComplete {
                mainAppShell
            } else {
                downloadGate
            }
        }
        .task {
            bootstrapViewModel.startIfNeeded()
        }
    }

    private var mainAppShell: some View {
        NavigationStack {
            switch onboardingRoute {
            case .welcome:
                WelcomeView {
                    onboardingRoute = .createNetwork
                } onJoinNetwork: {
                    onboardingRoute = .joinNetwork
                }

            case .createNetwork:
                TreeBuilderView(
                    viewModel: treeBuilderViewModel,
                    onBack: {
                        onboardingRoute = .welcome
                    },
                    onPublishNetwork: { config in
                        appNetworkCoordinator.publish(networkConfig: config)
                        appNetworkCoordinator.activateRoleClaiming(with: config)
                        onboardingRoute = .roleSelection
                    }
                )

            case .joinNetwork:
                JoinNetworkFlowView(
                    discoveryService: appNetworkCoordinator.discoveryService,
                    treeSyncService: appNetworkCoordinator.treeSyncService,
                    onJoined: { joinedConfig in
                        appNetworkCoordinator.activateRoleClaiming(with: joinedConfig)
                        onboardingRoute = .roleSelection
                    }
                ) {
                    onboardingRoute = .welcome
                }

            case .roleSelection:
                RoleSelectionView(
                    roleClaimService: appNetworkCoordinator.roleClaimService,
                    treeSyncService: appNetworkCoordinator.treeSyncService,
                    onRoleClaimed: {
                        onboardingRoute = .main
                    }
                ) {
                    onboardingRoute = .welcome
                }

            case .main:
                MainView(
                    viewModel: appNetworkCoordinator.mainViewModel,
                    onBackToRoleSelection: {
                        onboardingRoute = .roleSelection
                    }
                )
            }
        }
    }

    private var downloadGate: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Preparing On-Device AI Model")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Gemma 4 E4B INT4 (~6.7 GB)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: bootstrapViewModel.downloadProgress, total: 1)
                .progressViewStyle(.linear)
                .frame(maxWidth: 260)

            Text(bootstrapViewModel.progressLabel)
                .font(.headline.monospacedDigit())

            if let errorMessage = bootstrapViewModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Retry Download") {
                    bootstrapViewModel.retry()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("TacNet features are locked until model download completes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }
}

struct WelcomeView: View {
    let onCreateNetwork: () -> Void
    let onJoinNetwork: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to TacNet")
                .font(.title2)
                .fontWeight(.bold)

            Text("Set up a command tree as organiser or join an existing network.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button("Create Network", action: onCreateNetwork)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                Button("Join Network", action: onJoinNetwork)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)

            Spacer()
        }
        .navigationTitle("Onboarding")
    }
}

struct TreeBuilderView: View {
    @ObservedObject var viewModel: TreeBuilderViewModel
    let onBack: (() -> Void)?
    let onPublishNetwork: ((NetworkConfig) -> Void)?

    @State private var networkNameDraft: String
    @State private var pinDraft: String
    @State private var selectedNodeID: String?
    @State private var renameDraft: String
    @State private var newChildLabelDraft: String = ""
    @State private var isPublished = false

    init(
        viewModel: TreeBuilderViewModel,
        onBack: (() -> Void)? = nil,
        onPublishNetwork: ((NetworkConfig) -> Void)? = nil
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.onBack = onBack
        self.onPublishNetwork = onPublishNetwork
        _networkNameDraft = State(initialValue: viewModel.networkConfig.networkName)
        _pinDraft = State(initialValue: "")
        _selectedNodeID = State(initialValue: viewModel.networkConfig.tree.id)
        _renameDraft = State(initialValue: viewModel.networkConfig.tree.label)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Network Settings") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Network name", text: $networkNameDraft)
                            .textFieldStyle(.roundedBorder)

                        SecureField("Optional PIN", text: $pinDraft)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Apply Settings") {
                                _ = viewModel.updateNetworkName(networkNameDraft)
                                _ = viewModel.updatePin(pinDraft)
                            }
                            .buttonStyle(.borderedProminent)

                            Text("Version \(viewModel.currentVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            Button(isPublished ? "Update BLE Publish" : "Publish Network") {
                                onPublishNetwork?(viewModel.networkConfig)
                                isPublished = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(onPublishNetwork == nil)

                            if isPublished {
                                Label("Advertising live", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }

                        Text("Open slots: \(viewModel.networkConfig.openSlotCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Tree") {
                    VStack(alignment: .leading, spacing: 10) {
                        if viewModel.isTreeEmpty {
                            Text("Tree is empty. Add a child node to start building the hierarchy.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        TreeNodeTreeView(
                            node: viewModel.networkConfig.tree,
                            depth: 0,
                            selectedNodeID: selectedNodeID
                        ) { node in
                            selectedNodeID = node.id
                            renameDraft = node.label
                        }
                    }
                }

                GroupBox("Edit Selected Node") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(selectedNodeSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        TextField("Rename selected node", text: $renameDraft)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Rename") {
                                guard let selectedNodeID else { return }
                                _ = viewModel.renameNode(nodeID: selectedNodeID, newLabel: renameDraft)
                            }
                            .buttonStyle(.bordered)
                            .disabled(selectedNodeID == nil)

                            Button("Remove", role: .destructive) {
                                guard let selectedNodeID else { return }
                                if viewModel.removeNode(nodeID: selectedNodeID) {
                                    let root = viewModel.networkConfig.tree
                                    self.selectedNodeID = root.id
                                    renameDraft = root.label
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(selectedNodeID == nil)
                        }

                        TextField("New child label", text: $newChildLabelDraft)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button("Add Child") {
                                let parentID = selectedNodeID ?? viewModel.networkConfig.tree.id
                                guard let created = viewModel.addNode(parentID: parentID, label: newChildLabelDraft) else {
                                    return
                                }
                                selectedNodeID = created.id
                                renameDraft = created.label
                                newChildLabelDraft = ""
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Clear Tree", role: .destructive) {
                                guard viewModel.clearTree() else { return }
                                let root = viewModel.networkConfig.tree
                                selectedNodeID = root.id
                                renameDraft = root.label
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                GroupBox("BLE Distribution JSON") {
                    Text(viewModel.serializedTreeJSON(prettyPrinted: true) ?? "{}")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle("Tree Builder")
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back", action: onBack)
                }
            }
        }
        .onChange(of: selectedNodeID) { newValue in
            guard
                let newValue,
                let node = viewModel.node(withID: newValue)
            else {
                return
            }
            renameDraft = node.label
        }
        .onReceive(viewModel.$networkConfig) { updatedConfig in
            guard isPublished else {
                return
            }
            onPublishNetwork?(updatedConfig)
        }
    }

    private var selectedNodeSummary: String {
        guard
            let selectedNodeID,
            let node = viewModel.node(withID: selectedNodeID)
        else {
            return "No node selected."
        }

        let nodeLabel = node.label.isEmpty ? "(unnamed)" : node.label
        return "Selected: \(nodeLabel) • \(selectedNodeID)"
    }
}

private struct TreeNodeTreeView: View {
    let node: TreeNode
    let depth: Int
    let selectedNodeID: String?
    let onSelect: (TreeNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                onSelect(node)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.label.isEmpty ? "(unnamed node)" : node.label)
                            .font(.subheadline.weight(.medium))
                        Text(node.claimedBy ?? "Available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(node.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(depth) * 16)

            ForEach(node.children, id: \.id) { child in
                TreeNodeTreeView(
                    node: child,
                    depth: depth + 1,
                    selectedNodeID: selectedNodeID,
                    onSelect: onSelect
                )
            }
        }
    }

    private var rowBackground: Color {
        selectedNodeID == node.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)
    }
}

private struct JoinNetworkFlowView: View {
    @ObservedObject var discoveryService: NetworkDiscoveryService
    @ObservedObject var treeSyncService: TreeSyncService
    let onJoined: ((NetworkConfig) -> Void)?
    let onBack: () -> Void

    @State private var selectedPINNetwork: DiscoveredNetwork?
    @State private var pinDraft = ""
    @State private var joinErrorMessage: String?
    @State private var isJoining = false
    @State private var joinedConfig: NetworkConfig?

    var body: some View {
        Group {
            if let joinedConfig {
                joinedState(config: joinedConfig)
            } else if let selectedPINNetwork {
                pinEntryState(network: selectedPINNetwork)
            } else {
                NetworkScanView(
                    discoveryService: discoveryService,
                    onSelectNetwork: handleNetworkSelection,
                    onBack: onBack
                )
            }
        }
        .navigationTitle("Join")
        .onDisappear {
            discoveryService.stopScanning()
        }
    }

    @ViewBuilder
    private func pinEntryState(network: DiscoveredNetwork) -> some View {
        PinEntryView(
            network: network,
            pin: $pinDraft,
            errorMessage: joinErrorMessage,
            isJoining: isJoining,
            onSubmit: {
                Task {
                    await join(network: network, pin: pinDraft)
                }
            },
            onCancel: {
                selectedPINNetwork = nil
                pinDraft = ""
                joinErrorMessage = nil
            }
        )
    }

    @ViewBuilder
    private func joinedState(config: NetworkConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Joined \(config.networkName)", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Text("Version \(config.version) • Open slots \(config.openSlotCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox("Received Tree JSON") {
                ScrollView {
                    Text(prettyPrintedJSON(for: config) ?? "{}")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
            }

            HStack(spacing: 10) {
                Button("Join Another Network") {
                    joinedConfig = nil
                    selectedPINNetwork = nil
                    pinDraft = ""
                    joinErrorMessage = nil
                    discoveryService.startScanning(timeout: 10)
                }
                .buttonStyle(.bordered)

                Button("Back", action: onBack)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func handleNetworkSelection(_ network: DiscoveredNetwork) {
        joinErrorMessage = nil

        if network.requiresPIN {
            selectedPINNetwork = network
            pinDraft = ""
            return
        }

        Task {
            await join(network: network, pin: nil)
        }
    }

    private func join(network: DiscoveredNetwork, pin: String?) async {
        guard !isJoining else {
            return
        }

        isJoining = true
        defer { isJoining = false }

        do {
            let joined = try await treeSyncService.join(network: network, pin: pin)
            if let onJoined {
                onJoined(joined)
            } else {
                joinedConfig = joined
            }
            selectedPINNetwork = nil
            joinErrorMessage = nil
            discoveryService.stopScanning()
        } catch let error as TreeSyncJoinError {
            joinErrorMessage = joinErrorMessage(for: error)
        } catch {
            joinErrorMessage = error.localizedDescription
        }
    }

    private func joinErrorMessage(for error: TreeSyncJoinError) -> String {
        switch error {
        case .treeConfigUnavailable:
            return "Unable to fetch tree data from organiser. Try scanning again."
        case .networkMismatch:
            return "Discovered network details changed. Please rescan."
        case .pinRequired:
            return "PIN is required to join this network."
        case .invalidPIN:
            return "Incorrect PIN. Join blocked."
        }
    }

    private func prettyPrintedJSON(for config: NetworkConfig) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config.tree) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct NetworkScanView: View {
    @ObservedObject var discoveryService: NetworkDiscoveryService
    let onSelectNetwork: (DiscoveredNetwork) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if discoveryService.nearbyNetworks.isEmpty {
                VStack(spacing: 8) {
                    if discoveryService.isScanning {
                        ProgressView()
                    }

                    Text(discoveryService.isScanning ? "Scanning for nearby TacNet networks…" : "No networks found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(discoveryService.nearbyNetworks) { network in
                    Button {
                        onSelectNetwork(network)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(network.networkName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Open slots: \(network.openSlotCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: network.requiresPIN ? "lock.fill" : "lock.open.fill")
                                .foregroundStyle(network.requiresPIN ? .orange : .green)
                        }
                    }
                }
                .listStyle(.plain)
            }

            HStack(spacing: 12) {
                Button("Rescan (10s)") {
                    discoveryService.startScanning(timeout: 10)
                }
                .buttonStyle(.bordered)

                Button("Back", action: onBack)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal)
        .task {
            discoveryService.startScanning(timeout: 10)
        }
    }
}

private struct PinEntryView: View {
    let network: DiscoveredNetwork
    @Binding var pin: String
    let errorMessage: String?
    let isJoining: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Enter PIN for \(network.networkName)")
                .font(.headline)
                .multilineTextAlignment(.center)

            SecureField("Network PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Button(isJoining ? "Joining…" : "Join Network", action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(isJoining)
            }
        }
        .padding()
    }
}

private struct RoleSelectionView: View {
    @ObservedObject var roleClaimService: RoleClaimService
    @ObservedObject var treeSyncService: TreeSyncService
    let onRoleClaimed: () -> Void
    let onBack: () -> Void

    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            if let config = treeSyncService.localConfig {
                Text(config.networkName)
                    .font(.headline)

                Text("Tap an open node to claim your role.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                List(flattenedTree(from: config.tree)) { node in
                    Button {
                        handleClaimTap(nodeID: node.id)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(node.label.isEmpty ? "(unnamed node)" : node.label)
                                    .font(.subheadline.weight(.medium))
                                Text(claimStatusText(claimedBy: node.claimedBy))
                                    .font(.caption)
                                    .foregroundStyle(claimStatusColor(claimedBy: node.claimedBy))
                            }

                            Spacer(minLength: 8)
                            Text(node.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                        .padding(.leading, CGFloat(node.depth) * 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(node.claimedBy != nil && node.claimedBy != roleClaimService.localNodeIdentity)
                }
                .listStyle(.plain)

                if let rejection = roleClaimService.lastClaimRejection {
                    Text(rejectionMessage(for: rejection))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Release Role") {
                        let result = roleClaimService.releaseActiveClaim()
                        switch result {
                        case .released(let nodeID):
                            statusMessage = "Released \(nodeID)."
                        case .noActiveClaim:
                            statusMessage = "No claimed role to release."
                        default:
                            statusMessage = nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(roleClaimService.activeClaimNodeID == nil)

                    Button("Back", action: onBack)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 4)
            } else {
                Spacer()
                Text("No tree available yet. Join or publish a network first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Back", action: onBack)
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding(.horizontal)
        .navigationTitle("Role Selection")
    }

    private func handleClaimTap(nodeID: String) {
        let result = roleClaimService.claim(nodeID: nodeID)
        switch result {
        case .claimed(let claimedNodeID):
            statusMessage = "Claimed \(claimedNodeID)."
            onRoleClaimed()
        case .rejected(let reason):
            statusMessage = rejectionMessage(for: reason)
        case .unavailable:
            statusMessage = "Network config unavailable."
        default:
            statusMessage = nil
        }
    }

    private func claimStatusText(claimedBy: String?) -> String {
        guard let claimedBy else {
            return "Open"
        }

        if claimedBy == roleClaimService.localNodeIdentity {
            return "Claimed by you"
        }

        return "Claimed by \(claimedBy)"
    }

    private func claimStatusColor(claimedBy: String?) -> Color {
        guard let claimedBy else {
            return .green
        }
        return claimedBy == roleClaimService.localNodeIdentity ? .blue : .secondary
    }

    private func rejectionMessage(for reason: ClaimRejectionReason) -> String {
        switch reason {
        case .alreadyClaimed:
            return "Claim rejected: node already claimed."
        case .organiserWins:
            return "Claim rejected: organiser wins conflict resolution."
        case .nodeNotFound:
            return "Claim rejected: selected node no longer exists."
        }
    }

    private func flattenedTree(from root: TreeNode) -> [FlatTreeNode] {
        var nodes: [FlatTreeNode] = []
        append(node: root, depth: 0, into: &nodes)
        return nodes
    }

    private func append(node: TreeNode, depth: Int, into nodes: inout [FlatTreeNode]) {
        nodes.append(
            FlatTreeNode(
                id: node.id,
                label: node.label,
                depth: depth,
                claimedBy: node.claimedBy
            )
        )
        for child in node.children {
            append(node: child, depth: depth + 1, into: &nodes)
        }
    }

    private struct FlatTreeNode: Identifiable {
        let id: String
        let label: String
        let depth: Int
        let claimedBy: String?
    }
}

private struct MainView: View {
    @ObservedObject var viewModel: MainViewModel
    let onBackToRoleSelection: () -> Void

    @State private var isPressingPTT = false

    var body: some View {
        VStack(spacing: 14) {
            if let disconnectionMessage = viewModel.disconnectionMessage {
                Label(disconnectionMessage, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let errorMessage = viewModel.errorMessage, errorMessage != viewModel.disconnectionMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.feedEntries.isEmpty {
                        Text("No live entries yet. Incoming sibling broadcasts and compaction summaries will appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(viewModel.feedEntries) { entry in
                            LiveFeedEntryRow(entry: entry)
                        }
                    }
                }
                .padding(.horizontal)
            }

            pttControl
                .padding(.bottom, 12)
        }
        .navigationTitle("Main Feed")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Roles", action: onBackToRoleSelection)
            }
        }
        .onAppear {
            viewModel.refreshConnectionState()
        }
    }

    private var pttControl: some View {
        ZStack {
            Circle()
                .fill(viewModel.pttButtonColor.opacity(0.20))
                .overlay(
                    Circle()
                        .stroke(viewModel.pttButtonColor, lineWidth: 3)
                )

            VStack(spacing: 8) {
                Image(systemName: viewModel.pttButtonSymbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(viewModel.pttButtonColor)
                Text(viewModel.pttButtonTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(width: 220, height: 220)
        .opacity(viewModel.isPTTDisabled ? 0.55 : 1.0)
        .contentShape(Circle())
        .allowsHitTesting(!viewModel.isPTTDisabled || viewModel.pttState == .recording)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressingPTT else {
                        return
                    }
                    isPressingPTT = true
                    Task {
                        await viewModel.startPushToTalk()
                    }
                }
                .onEnded { _ in
                    guard isPressingPTT else {
                        return
                    }
                    isPressingPTT = false
                    Task {
                        await viewModel.stopPushToTalk()
                    }
                }
        )
    }
}

private struct LiveFeedEntryRow: View {
    let entry: MainViewModel.FeedEntry

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.senderRole)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(entry.type.badgeTitle)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(entry.type.badgeForegroundColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(entry.type.badgeBackgroundColor)
                    .clipShape(Capsule())
                Spacer(minLength: 8)
            }

            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
final class MainViewModel: ObservableObject {
    enum PTTState: Equatable {
        case idle
        case recording
        case sending
    }

    enum FeedEntryType: String, Equatable {
        case broadcast = "BROADCAST"
        case compaction = "COMPACTION"

        var badgeTitle: String {
            rawValue
        }

        var badgeForegroundColor: Color {
            switch self {
            case .broadcast:
                return .blue
            case .compaction:
                return .orange
            }
        }

        var badgeBackgroundColor: Color {
            switch self {
            case .broadcast:
                return Color.blue.opacity(0.18)
            case .compaction:
                return Color.orange.opacity(0.18)
            }
        }
    }

    struct FeedEntry: Identifiable, Equatable {
        let id: UUID
        let senderRole: String
        let timestamp: Date
        let type: FeedEntryType
        let text: String
    }

    static let disconnectedErrorText = "Disconnected from mesh. Reconnect to use push-to-talk."

    @Published private(set) var feedEntries: [FeedEntry] = []
    @Published private(set) var pttState: PTTState = .idle
    @Published private(set) var isConnected: Bool
    @Published private(set) var errorMessage: String?

    private let meshService: BluetoothMeshService
    private let roleClaimService: RoleClaimService
    private let localDeviceID: String
    private let messageRouter: MessageRouter
    private let audioService: AudioService
    private var seenMessageIDs: Set<UUID> = []

    init(
        meshService: BluetoothMeshService,
        roleClaimService: RoleClaimService,
        localDeviceID: String,
        messageRouter: MessageRouter = MessageRouter(),
        audioService: AudioService = AudioService()
    ) {
        self.meshService = meshService
        self.roleClaimService = roleClaimService
        self.localDeviceID = localDeviceID
        self.messageRouter = messageRouter
        self.audioService = audioService
        isConnected = !meshService.connectedPeerIDs.isEmpty
        if !isConnected {
            errorMessage = Self.disconnectedErrorText
        }
    }

    var isPTTDisabled: Bool {
        !isConnected || pttState == .sending
    }

    var disconnectionMessage: String? {
        isConnected ? nil : Self.disconnectedErrorText
    }

    var pttButtonTitle: String {
        switch pttState {
        case .idle:
            return "Hold to Talk"
        case .recording:
            return "Recording…\nRelease to Send"
        case .sending:
            return "Sending…"
        }
    }

    var pttButtonSymbol: String {
        switch pttState {
        case .idle:
            return "mic.fill"
        case .recording:
            return "record.circle.fill"
        case .sending:
            return "paperplane.fill"
        }
    }

    var pttButtonColor: Color {
        if !isConnected {
            return .gray
        }
        switch pttState {
        case .idle:
            return .blue
        case .recording:
            return .red
        case .sending:
            return .orange
        }
    }

    func refreshConnectionState() {
        let hasConnectedPeers = !meshService.connectedPeerIDs.isEmpty
        isConnected = hasConnectedPeers
        if hasConnectedPeers {
            if errorMessage == Self.disconnectedErrorText {
                errorMessage = nil
            }
        } else if pttState != .recording {
            errorMessage = Self.disconnectedErrorText
        }
    }

    func handlePeerConnectionStateChanged(peerID _: UUID, state _: PeerConnectionState) {
        refreshConnectionState()
    }

    func handleIncomingMessage(_ message: Message) {
        guard !seenMessageIDs.contains(message.id),
              let context = localContext() else {
            return
        }

        let entryType: FeedEntryType
        let textValue: String

        switch message.type {
        case .broadcast:
            guard shouldDisplaySiblingBroadcast(message, localNodeID: context.localNodeID, tree: context.config.tree),
                  let transcript = message.payload.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty else {
                return
            }
            entryType = .broadcast
            textValue = transcript

        case .compaction:
            guard messageRouter.shouldDisplay(message, for: context.localNodeID, in: context.config.tree),
                  let summary = message.payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty else {
                return
            }
            entryType = .compaction
            textValue = summary

        default:
            return
        }

        seenMessageIDs.insert(message.id)
        feedEntries.append(
            FeedEntry(
                id: message.id,
                senderRole: message.senderRole,
                timestamp: message.timestamp,
                type: entryType,
                text: textValue
            )
        )
        feedEntries.sort { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }
    }

    func startPushToTalk() async {
        guard pttState == .idle else {
            return
        }

        guard isConnected else {
            errorMessage = Self.disconnectedErrorText
            return
        }

        guard localContext() != nil else {
            errorMessage = "Claim a role before transmitting."
            return
        }

        do {
            try await audioService.pttPressed()
            pttState = .recording
            errorMessage = nil
        } catch {
            pttState = .idle
            errorMessage = "Unable to start recording: \(error.localizedDescription)"
        }
    }

    func stopPushToTalk() async {
        guard pttState == .recording else {
            return
        }

        pttState = .sending

        do {
            let queuedSequence = try await audioService.pttReleased()
            guard let queuedSequence else {
                pttState = .idle
                return
            }

            await audioService.waitForIdle()
            let history = await audioService.transcriptHistory
            guard let transcript = history.first(where: { $0.sequence == queuedSequence })?.transcript,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                pttState = .idle
                return
            }

            publishLocalTranscript(transcript)
            pttState = .idle
        } catch {
            pttState = .idle
            errorMessage = "Unable to send message: \(error.localizedDescription)"
        }
    }

    private func publishLocalTranscript(_ transcript: String) {
        guard let context = localContext() else {
            errorMessage = "Claim a role before transmitting."
            return
        }

        let outboundMessage = messageRouter.makeBroadcastMessage(
            transcript: transcript,
            senderID: localDeviceID,
            senderNodeID: context.localNodeID,
            senderRole: context.senderRole,
            in: context.config.tree
        )
        meshService.publish(outboundMessage)
    }

    private struct LocalContext {
        let config: NetworkConfig
        let localNodeID: String
        let senderRole: String
    }

    private func localContext() -> LocalContext? {
        guard let config = roleClaimService.networkConfig else {
            return nil
        }

        let localNodeID = roleClaimService.activeClaimNodeID
            ?? findNodeID(claimedBy: localDeviceID, in: config.tree)
        guard let localNodeID else {
            return nil
        }

        let senderRole = findNode(withID: localNodeID, in: config.tree)?.label ?? "participant"
        return LocalContext(config: config, localNodeID: localNodeID, senderRole: senderRole)
    }

    private func shouldDisplaySiblingBroadcast(_ message: Message, localNodeID: String, tree: TreeNode) -> Bool {
        guard let senderNodeID = resolveSenderNodeID(for: message, in: tree),
              senderNodeID != localNodeID,
              let localParentID = TreeHelpers.parent(of: localNodeID, in: tree)?.id,
              let senderParentID = TreeHelpers.parent(of: senderNodeID, in: tree)?.id else {
            return false
        }

        return localParentID == senderParentID
    }

    private func resolveSenderNodeID(for message: Message, in tree: TreeNode) -> String? {
        if TreeHelpers.level(of: message.senderID, in: tree) != nil {
            return message.senderID
        }
        return findNodeID(claimedBy: message.senderID, in: tree)
    }

    private func findNodeID(claimedBy deviceID: String, in tree: TreeNode) -> String? {
        if tree.claimedBy == deviceID {
            return tree.id
        }

        for child in tree.children {
            if let nodeID = findNodeID(claimedBy: deviceID, in: child) {
                return nodeID
            }
        }
        return nil
    }

    private func findNode(withID nodeID: String, in tree: TreeNode) -> TreeNode? {
        if tree.id == nodeID {
            return tree
        }

        for child in tree.children {
            if let node = findNode(withID: nodeID, in: child) {
                return node
            }
        }
        return nil
    }
}

@MainActor
final class AppNetworkCoordinator: ObservableObject {
    let localDeviceID: String
    let meshService: BluetoothMeshService
    let discoveryService: NetworkDiscoveryService
    let treeSyncService: TreeSyncService
    let roleClaimService: RoleClaimService
    let mainViewModel: MainViewModel

    init(
        meshService: BluetoothMeshService = BluetoothMeshService(),
        localDeviceID: String = ProcessInfo.processInfo.hostName
    ) {
        self.localDeviceID = localDeviceID
        self.meshService = meshService
        discoveryService = NetworkDiscoveryService(meshService: meshService)
        treeSyncService = TreeSyncService(meshService: meshService)
        roleClaimService = RoleClaimService(
            meshService: meshService,
            treeSyncService: treeSyncService,
            localDeviceID: localDeviceID
        )
        mainViewModel = MainViewModel(
            meshService: meshService,
            roleClaimService: roleClaimService,
            localDeviceID: localDeviceID
        )

        meshService.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                self?.roleClaimService.handleIncomingMessage(message)
                self?.mainViewModel.handleIncomingMessage(message)
            }
        }

        meshService.onPeerConnectionStateChanged = { [weak self] peerID, state in
            Task { @MainActor in
                self?.roleClaimService.handlePeerStateChange(peerID: peerID, state: state)
                self?.mainViewModel.handlePeerConnectionStateChanged(peerID: peerID, state: state)
            }
        }
    }

    func publish(networkConfig: NetworkConfig) {
        treeSyncService.setLocalConfig(networkConfig)
        meshService.publishNetwork(networkConfig)
    }

    func activateRoleClaiming(with config: NetworkConfig) {
        treeSyncService.setLocalConfig(config)
        meshService.start()
    }
}

@MainActor
final class AppBootstrapViewModel: ObservableObject {
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isDownloadComplete = false
    @Published private(set) var errorMessage: String?

    private let downloadService: ModelDownloadService
    private var hasStarted = false

    init(downloadService: ModelDownloadService = .live) {
        self.downloadService = downloadService
    }

    var progressLabel: String {
        "\(Int((downloadProgress * 100).rounded()))%"
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true

        Task {
            if await downloadService.canUseTacticalFeatures() {
                downloadProgress = 1
                isDownloadComplete = true
                errorMessage = nil
                return
            }

            do {
                _ = try await downloadService.ensureModelAvailable { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.downloadProgress = max(self.downloadProgress, progress)
                    }
                }

                downloadProgress = 1
                isDownloadComplete = true
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func retry() {
        hasStarted = false
        errorMessage = nil
        startIfNeeded()
    }
}

#Preview {
    ContentView()
}
