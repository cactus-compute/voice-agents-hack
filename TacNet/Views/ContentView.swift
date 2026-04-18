import SwiftUI
import Combine
import UniformTypeIdentifiers

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
                TacNetTabShellView(
                    mainViewModel: appNetworkCoordinator.mainViewModel,
                    treeViewModel: appNetworkCoordinator.treeViewModel,
                    dataFlowViewModel: appNetworkCoordinator.dataFlowViewModel,
                    settingsViewModel: appNetworkCoordinator.settingsViewModel,
                    afterActionReviewViewModel: appNetworkCoordinator.afterActionReviewViewModel,
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
                            selectedNodeID: selectedNodeID,
                            onDropNode: handleTreeNodeDrop
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

    private func handleTreeNodeDrop(draggedNodeID: String, onto targetNodeID: String) -> Bool {
        guard draggedNodeID != targetNodeID else {
            return false
        }

        let treeSnapshot = viewModel.networkConfig.tree
        let sourceParentID = TreeHelpers.parent(of: draggedNodeID, in: treeSnapshot)?.id
        let targetParentID = TreeHelpers.parent(of: targetNodeID, in: treeSnapshot)?.id

        let didApplyDrop: Bool
        if let sourceParentID, sourceParentID == targetParentID {
            didApplyDrop = viewModel.reorderNode(nodeID: draggedNodeID, beforeSiblingID: targetNodeID)
        } else {
            didApplyDrop = viewModel.moveNode(nodeID: draggedNodeID, newParentID: targetNodeID)
        }

        guard didApplyDrop else {
            return false
        }

        selectedNodeID = draggedNodeID
        if let movedNode = viewModel.node(withID: draggedNodeID) {
            renameDraft = movedNode.label
        }
        return true
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
    let onDropNode: (String, String) -> Bool
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
            .onDrag {
                onSelect(node)
                return NSItemProvider(object: node.id as NSString)
            }
            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                performDrop(providers: providers, targetNodeID: node.id)
            }

            ForEach(node.children, id: \.id) { child in
                TreeNodeTreeView(
                    node: child,
                    depth: depth + 1,
                    selectedNodeID: selectedNodeID,
                    onDropNode: onDropNode,
                    onSelect: onSelect
                )
            }
        }
    }

    private func performDrop(providers: [NSItemProvider], targetNodeID: String) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let sourceNodeID = object as? NSString else {
                return
            }
            DispatchQueue.main.async {
                _ = onDropNode(sourceNodeID as String, targetNodeID)
            }
        }
        return true
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

enum TacNetTab: String, CaseIterable, Identifiable {
    case main
    case treeView
    case dataFlow
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main:
            return "Main"
        case .treeView:
            return "Tree View"
        case .dataFlow:
            return "Data Flow"
        case .settings:
            return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .main:
            return "dot.radiowaves.left.and.right"
        case .treeView:
            return "point.3.filled.connected.trianglepath.dotted"
        case .dataFlow:
            return "arrow.triangle.branch"
        case .settings:
            return "gearshape"
        }
    }
}

private struct TacNetTabShellView: View {
    @ObservedObject var mainViewModel: MainViewModel
    @ObservedObject var treeViewModel: TreeViewModel
    @ObservedObject var dataFlowViewModel: DataFlowViewModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    @ObservedObject var afterActionReviewViewModel: AfterActionReviewViewModel
    let onBackToRoleSelection: () -> Void

    @State private var selectedTab: TacNetTab = .main

    var body: some View {
        TabView(selection: $selectedTab) {
            MainView(
                viewModel: mainViewModel,
                onBackToRoleSelection: onBackToRoleSelection
            )
            .tabItem {
                Label(TacNetTab.main.title, systemImage: TacNetTab.main.systemImage)
            }
            .tag(TacNetTab.main)

            TreeView(viewModel: treeViewModel)
                .tabItem {
                    Label(TacNetTab.treeView.title, systemImage: TacNetTab.treeView.systemImage)
                }
                .tag(TacNetTab.treeView)

            DataFlowView(viewModel: dataFlowViewModel)
                .tabItem {
                    Label(TacNetTab.dataFlow.title, systemImage: TacNetTab.dataFlow.systemImage)
                }
                .tag(TacNetTab.dataFlow)

            SettingsView(
                viewModel: settingsViewModel,
                afterActionReviewViewModel: afterActionReviewViewModel,
                onReleaseRole: onBackToRoleSelection
            )
                .tabItem {
                    Label(TacNetTab.settings.title, systemImage: TacNetTab.settings.systemImage)
                }
                .tag(TacNetTab.settings)
        }
        .accessibilityIdentifier("tacnet.tab.root")
    }
}

@MainActor
final class TreeViewModel: ObservableObject {
    enum NodeStatus: Equatable {
        case active
        case idle
        case disconnected

        var color: Color {
            switch self {
            case .active:
                return .green
            case .idle:
                return .orange
            case .disconnected:
                return .red
            }
        }

        var labelText: String {
            switch self {
            case .active:
                return "Active"
            case .idle:
                return "Idle"
            case .disconnected:
                return "Disconnected"
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let depth: Int
        let claimedByText: String
        let compactionDisplayText: String?
        let isCompactionExpanded: Bool
    }

    private struct CompactionEntry: Equatable {
        let summary: String
        let senderRole: String
        let updatedAt: Date
    }

    @Published private(set) var rows: [Row] = []

    private let roleClaimService: RoleClaimService
    private let localDeviceID: String
    private let nowProvider: () -> Date

    private var lastActivityByNodeID: [String: Date] = [:]
    private var compactionsByParentNodeID: [String: CompactionEntry] = [:]
    private var expandedCompactionNodeIDs: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        roleClaimService: RoleClaimService,
        localDeviceID: String,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.roleClaimService = roleClaimService
        self.localDeviceID = localDeviceID
        self.nowProvider = nowProvider

        roleClaimService.$networkConfig
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshFromCurrentTree()
            }
            .store(in: &cancellables)

        refreshFromCurrentTree()
    }

    func refreshFromCurrentTree() {
        refreshRows(now: nowProvider())
    }

    func status(for nodeID: String, now: Date = Date()) -> NodeStatus {
        let referenceDate = lastActivityByNodeID[nodeID] ?? now
        let elapsed = max(0, now.timeIntervalSince(referenceDate))

        if elapsed > 60 {
            return .disconnected
        }
        if elapsed > 30 {
            return .idle
        }
        return .active
    }

    func toggleCompactionExpansion(for nodeID: String) {
        if expandedCompactionNodeIDs.contains(nodeID) {
            expandedCompactionNodeIDs.remove(nodeID)
        } else {
            expandedCompactionNodeIDs.insert(nodeID)
        }
        refreshRows(now: nowProvider())
    }

    func handleIncomingMessage(_ message: Message) {
        guard let tree = roleClaimService.networkConfig?.tree else {
            return
        }

        if let senderNodeID = resolveSenderNodeID(for: message, in: tree) {
            lastActivityByNodeID[senderNodeID] = message.timestamp
        }

        if message.type == .compaction,
           let summary = message.payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty,
           let parentNodeID = resolvedParentNodeID(for: message, in: tree) {
            compactionsByParentNodeID[parentNodeID] = CompactionEntry(
                summary: summary,
                senderRole: message.senderRole,
                updatedAt: message.timestamp
            )
        }

        refreshRows(now: nowProvider())
    }

    func handlePeerConnectionStateChanged(peerID: UUID, state: PeerConnectionState) {
        guard state == .connected,
              let tree = roleClaimService.networkConfig?.tree,
              let nodeID = findNodeID(claimedBy: peerID.uuidString, in: tree) else {
            return
        }

        lastActivityByNodeID[nodeID] = nowProvider()
        refreshRows(now: nowProvider())
    }

    private func refreshRows(now: Date) {
        guard let tree = roleClaimService.networkConfig?.tree else {
            rows = []
            lastActivityByNodeID = [:]
            compactionsByParentNodeID = [:]
            expandedCompactionNodeIDs = []
            return
        }

        let knownNodeIDs = collectNodeIDs(in: tree)
        lastActivityByNodeID = lastActivityByNodeID.filter { knownNodeIDs.contains($0.key) }
        compactionsByParentNodeID = compactionsByParentNodeID.filter { knownNodeIDs.contains($0.key) }
        expandedCompactionNodeIDs = expandedCompactionNodeIDs.intersection(knownNodeIDs)

        var flattenedRows: [Row] = []
        appendRows(from: tree, depth: 0, now: now, into: &flattenedRows)
        rows = flattenedRows
    }

    private func appendRows(from node: TreeNode, depth: Int, now: Date, into rows: inout [Row]) {
        if lastActivityByNodeID[node.id] == nil {
            if node.claimedBy == localDeviceID {
                lastActivityByNodeID[node.id] = now
            } else {
                lastActivityByNodeID[node.id] = now
            }
        }

        let compaction = compactionsByParentNodeID[node.id]
        let isExpanded = expandedCompactionNodeIDs.contains(node.id)
        let displaySummary = compaction.map { entry in
            if isExpanded {
                return entry.summary
            }
            return Self.truncatedSummary(entry.summary)
        }

        rows.append(
            Row(
                id: node.id,
                label: node.label,
                depth: depth,
                claimedByText: "claimed_by: \(node.claimedBy?.isEmpty == false ? node.claimedBy! : "Available")",
                compactionDisplayText: displaySummary,
                isCompactionExpanded: isExpanded
            )
        )

        for child in node.children {
            appendRows(from: child, depth: depth + 1, now: now, into: &rows)
        }
    }

    private func collectNodeIDs(in node: TreeNode) -> Set<String> {
        var nodeIDs: Set<String> = [node.id]
        for child in node.children {
            nodeIDs.formUnion(collectNodeIDs(in: child))
        }
        return nodeIDs
    }

    private func resolveSenderNodeID(for message: Message, in tree: TreeNode) -> String? {
        if TreeHelpers.level(of: message.senderID, in: tree) != nil {
            return message.senderID
        }
        return findNodeID(claimedBy: message.senderID, in: tree)
    }

    private func resolvedParentNodeID(for message: Message, in tree: TreeNode) -> String? {
        if let parentID = message.parentID {
            return parentID
        }
        guard let senderNodeID = resolveSenderNodeID(for: message, in: tree) else {
            return nil
        }
        return TreeHelpers.parent(of: senderNodeID, in: tree)?.id
    }

    private func findNodeID(claimedBy ownerID: String, in tree: TreeNode) -> String? {
        if tree.claimedBy == ownerID {
            return tree.id
        }

        for child in tree.children {
            if let nodeID = findNodeID(claimedBy: ownerID, in: child) {
                return nodeID
            }
        }
        return nil
    }

    private static func truncatedSummary(_ summary: String, maxCharacters: Int = 84) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else {
            return trimmed
        }

        let prefix = trimmed.prefix(max(1, maxCharacters - 1))
        return "\(prefix)…"
    }
}

struct TreeView: View {
    @ObservedObject var viewModel: TreeViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timelineContext in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.rows.isEmpty {
                        Text("No tree available yet. Join or publish a network first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(viewModel.rows) { row in
                            TreeNodeStatusRowView(
                                row: row,
                                status: viewModel.status(for: row.id, now: timelineContext.date)
                            ) {
                                viewModel.toggleCompactionExpansion(for: row.id)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Tree View")
        .onAppear {
            viewModel.refreshFromCurrentTree()
        }
        .accessibilityIdentifier("tacnet.tree.root")
    }
}

private struct TreeNodeStatusRowView: View {
    let row: TreeViewModel.Row
    let status: TreeViewModel.NodeStatus
    let onToggleCompaction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(status.color)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(Text(status.labelText))

                Text(row.label.isEmpty ? "(unnamed node)" : row.label)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Text(status.labelText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(row.claimedByText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let compactionSummary = row.compactionDisplayText {
                Button(action: onToggleCompaction) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compaction Summary")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                        Text(compactionSummary)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.isCompactionExpanded ? "Tap to collapse" : "Tap to expand")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.leading, CGFloat(row.depth) * 14)
        .accessibilityIdentifier("tacnet.tree.row.\(row.id)")
    }
}

@MainActor
final class DataFlowViewModel: ObservableObject {
    struct IncomingEntry: Identifiable, Equatable {
        var id: UUID { messageID }
        let messageID: UUID
        let timestamp: Date
        let senderID: String
        let senderRole: String
        let typeLabel: String
    }

    struct OutgoingEntry: Identifiable, Equatable {
        var id: UUID { messageID }
        let messageID: UUID
        let timestamp: Date
        let destinationNodeID: String
        let sourceNodeIDs: [String]
        let outputText: String
    }

    struct ProcessingSnapshot: Equatable {
        let status: CompactionEngine.ProcessingStatus
        let triggerReason: CompactionEngine.TriggerReason?
        let latencyMilliseconds: Double?
        let inputTokenCount: Int
        let outputTokenCount: Int
        let compressionRatio: Double?
        let sourceMessageCount: Int

        static let idle = ProcessingSnapshot(
            status: .idle,
            triggerReason: nil,
            latencyMilliseconds: nil,
            inputTokenCount: 0,
            outputTokenCount: 0,
            compressionRatio: nil,
            sourceMessageCount: 0
        )

        var statusLabel: String {
            switch status {
            case .idle:
                return "Idle"
            case .compacting:
                return "Compacting"
            }
        }

        var triggerReasonLabel: String {
            guard let triggerReason else {
                return "—"
            }
            switch triggerReason {
            case .timeWindow:
                return "Time Window"
            case .messageCount:
                return "Message Count"
            case .priorityKeyword:
                return "Priority Keyword"
            case .manual:
                return "Manual"
            }
        }

        var latencyLabel: String {
            guard let latencyMilliseconds else {
                return "—"
            }
            return "\(Int(latencyMilliseconds.rounded())) ms"
        }

        var compressionRatioLabel: String {
            guard let compressionRatio else {
                return "—"
            }
            return String(format: "%.2fx", compressionRatio)
        }
    }

    @Published private(set) var incomingEntries: [IncomingEntry] = []
    @Published private(set) var outgoingEntries: [OutgoingEntry] = []
    @Published private(set) var processing: ProcessingSnapshot = .idle

    func handleIncomingMessage(_ message: Message) {
        incomingEntries.append(
            IncomingEntry(
                messageID: message.id,
                timestamp: message.timestamp,
                senderID: message.senderID,
                senderRole: message.senderRole,
                typeLabel: message.type.rawValue
            )
        )
        incomingEntries.sort { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }
    }

    func handleProcessingMetrics(_ metrics: CompactionEngine.ProcessingMetrics) {
        processing = ProcessingSnapshot(
            status: metrics.status,
            triggerReason: metrics.triggerReason,
            latencyMilliseconds: metrics.latencyMilliseconds,
            inputTokenCount: metrics.inputTokenCount,
            outputTokenCount: metrics.outputTokenCount,
            compressionRatio: metrics.compressionRatio,
            sourceMessageCount: metrics.sourceMessageCount
        )
    }

    func handleOutgoingCompaction(_ emission: CompactionEngine.CompactionEmission) {
        let trimmedOutput = emission.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return
        }

        outgoingEntries.append(
            OutgoingEntry(
                messageID: emission.message.id,
                timestamp: emission.generatedAt,
                destinationNodeID: emission.destinationNodeID ?? "N/A",
                sourceNodeIDs: emission.sourceNodeIDs,
                outputText: trimmedOutput
            )
        )
        outgoingEntries.sort { lhs, rhs in
            lhs.timestamp > rhs.timestamp
        }
    }

    func resetCompactionTelemetry() {
        processing = .idle
        outgoingEntries = []
    }
}

struct DataFlowView: View {
    @ObservedObject var viewModel: DataFlowViewModel

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                incomingSection
                processingSection
                outgoingSection
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle("Data Flow")
        .accessibilityIdentifier("tacnet.dataflow.root")
    }

    private var incomingSection: some View {
        GroupBox("INCOMING") {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.incomingEntries.isEmpty {
                    Text("No received messages yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.incomingEntries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.senderRole.isEmpty ? entry.senderID : entry.senderRole)
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 8)
                                Text(Self.timestampFormatter.string(from: entry.timestamp))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 8) {
                                Text(entry.typeLabel)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.15))
                                    .clipShape(Capsule())
                                Text(entry.senderID)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var processingSection: some View {
        GroupBox("PROCESSING") {
            VStack(alignment: .leading, spacing: 8) {
                processingMetricRow(title: "Gemma 4 Status", value: viewModel.processing.statusLabel)
                processingMetricRow(title: "Trigger Reason", value: viewModel.processing.triggerReasonLabel)
                processingMetricRow(title: "Latency", value: viewModel.processing.latencyLabel)
                processingMetricRow(title: "Input Tokens", value: "\(viewModel.processing.inputTokenCount)")
                processingMetricRow(title: "Output Tokens", value: "\(viewModel.processing.outputTokenCount)")
                processingMetricRow(title: "Compression Ratio", value: viewModel.processing.compressionRatioLabel)
                processingMetricRow(title: "Source Messages", value: "\(viewModel.processing.sourceMessageCount)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outgoingSection: some View {
        GroupBox("OUTGOING") {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.outgoingEntries.isEmpty {
                    Text("No emitted compactions yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.outgoingEntries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Destination: \(entry.destinationNodeID)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Text(Self.timestampFormatter.string(from: entry.timestamp))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            Text("Source IDs: \(entry.sourceNodeIDs.isEmpty ? "—" : entry.sourceNodeIDs.joined(separator: ", "))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)

                            Text(entry.outputText)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func processingMetricRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    struct TreeRow: Identifiable, Equatable {
        let id: String
        let label: String
        let depth: Int
        let claimedBy: String?

        var displayLabel: String {
            label.isEmpty ? "(unnamed node)" : label
        }

        var claimedByText: String {
            if let claimedBy, !claimedBy.isEmpty {
                return "claimed_by: \(claimedBy)"
            }
            return "claimed_by: Available"
        }

        var promoteDisplayText: String {
            if let claimedBy, !claimedBy.isEmpty {
                return "\(displayLabel) (\(claimedBy))"
            }
            return displayLabel
        }
    }

    @Published var selectedNodeID: String?
    @Published var renameDraft: String = ""
    @Published var newChildLabelDraft: String = ""
    @Published var promoteTargetNodeID: String?
    @Published private(set) var statusMessage: String?

    private let roleClaimService: RoleClaimService
    private var cancellables: Set<AnyCancellable> = []

    init(roleClaimService: RoleClaimService) {
        self.roleClaimService = roleClaimService
        synchronizeSelectionAndTargets()

        roleClaimService.$networkConfig
            .combineLatest(roleClaimService.$activeClaimNodeID)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else {
                    return
                }
                self.objectWillChange.send()
                self.synchronizeSelectionAndTargets()
            }
            .store(in: &cancellables)
    }

    var showsOrganiserControls: Bool {
        roleClaimService.isOrganiser
    }

    var isEditTreeButtonVisible: Bool {
        showsOrganiserControls
    }

    var isEditTreeButtonDisabled: Bool {
        !showsOrganiserControls
    }

    var canReleaseRole: Bool {
        roleClaimService.activeClaimNodeID != nil
    }

    var claimedRoleDescription: String {
        guard let activeClaimNodeID = roleClaimService.activeClaimNodeID else {
            return "No active role claimed."
        }
        return "Claimed node: \(activeClaimNodeID)"
    }

    var treeRows: [TreeRow] {
        guard let tree = roleClaimService.networkConfig?.tree else {
            return []
        }

        var rows: [TreeRow] = []
        appendRows(from: tree, depth: 0, into: &rows)
        return rows
    }

    var promotableNodeRows: [TreeRow] {
        guard let config = roleClaimService.networkConfig else {
            return []
        }

        return treeRows.filter { row in
            guard let claimedBy = row.claimedBy, !claimedBy.isEmpty else {
                return false
            }
            return claimedBy != config.createdBy
        }
    }

    var canPromoteSelectedNode: Bool {
        showsOrganiserControls && promoteTargetNodeID != nil
    }

    var canRenameSelectedNode: Bool {
        showsOrganiserControls &&
            selectedNodeID != nil &&
            !renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canAddChildNode: Bool {
        showsOrganiserControls &&
            !newChildLabelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (selectedNodeID != nil || roleClaimService.networkConfig?.tree.id != nil)
    }

    var canRemoveSelectedNode: Bool {
        guard showsOrganiserControls,
              let selectedNodeID,
              let rootNodeID = roleClaimService.networkConfig?.tree.id else {
            return false
        }
        return selectedNodeID != rootNodeID
    }

    func selectNode(_ nodeID: String) {
        selectedNodeID = nodeID
        if let tree = roleClaimService.networkConfig?.tree,
           let node = findNode(withID: nodeID, in: tree) {
            renameDraft = node.label
        }
    }

    @discardableResult
    func releaseRole() -> Bool {
        let result = roleClaimService.releaseActiveClaim()
        switch result {
        case .released(let nodeID):
            statusMessage = "Released \(nodeID)."
            synchronizeSelectionAndTargets()
            return true
        case .noActiveClaim:
            statusMessage = "No claimed role to release."
            return false
        case .unavailable:
            statusMessage = "Network unavailable."
            return false
        case .claimed, .rejected:
            statusMessage = nil
            return false
        }
    }

    @discardableResult
    func addChildToSelectedNode() -> Bool {
        guard showsOrganiserControls else {
            statusMessage = "Only organiser can edit the tree."
            return false
        }

        guard let parentID = selectedNodeID ?? roleClaimService.networkConfig?.tree.id else {
            statusMessage = "No tree available to edit."
            return false
        }

        guard let createdNode = roleClaimService.addNode(parentID: parentID, label: newChildLabelDraft) else {
            statusMessage = "Unable to add child node."
            return false
        }

        selectedNodeID = createdNode.id
        renameDraft = createdNode.label
        newChildLabelDraft = ""
        statusMessage = "Added \(createdNode.label)."
        synchronizeSelectionAndTargets()
        return true
    }

    @discardableResult
    func renameSelectedNode() -> Bool {
        guard showsOrganiserControls else {
            statusMessage = "Only organiser can edit the tree."
            return false
        }

        guard let selectedNodeID else {
            statusMessage = "Select a node to rename."
            return false
        }

        guard roleClaimService.renameNode(nodeID: selectedNodeID, newLabel: renameDraft) else {
            statusMessage = "Unable to rename selected node."
            return false
        }

        statusMessage = "Renamed \(selectedNodeID)."
        synchronizeSelectionAndTargets()
        return true
    }

    @discardableResult
    func removeSelectedNode() -> Bool {
        guard showsOrganiserControls else {
            statusMessage = "Only organiser can edit the tree."
            return false
        }

        guard let selectedNodeID else {
            statusMessage = "Select a node to remove."
            return false
        }

        guard roleClaimService.removeNode(nodeID: selectedNodeID) else {
            statusMessage = "Unable to remove selected node."
            return false
        }

        statusMessage = "Removed \(selectedNodeID)."
        synchronizeSelectionAndTargets()
        return true
    }

    @discardableResult
    func handleNodeDrop(draggedNodeID: String, onto targetNodeID: String) -> Bool {
        guard showsOrganiserControls else {
            statusMessage = "Only organiser can edit the tree."
            return false
        }

        guard draggedNodeID != targetNodeID else {
            statusMessage = "Drop target is unchanged."
            return false
        }

        guard let tree = roleClaimService.networkConfig?.tree else {
            statusMessage = "No tree available to edit."
            return false
        }

        let sourceParentID = TreeHelpers.parent(of: draggedNodeID, in: tree)?.id
        let targetParentID = TreeHelpers.parent(of: targetNodeID, in: tree)?.id

        let didApplyDrop: Bool
        if let sourceParentID, sourceParentID == targetParentID {
            didApplyDrop = roleClaimService.reorderNode(nodeID: draggedNodeID, beforeSiblingID: targetNodeID)
            statusMessage = didApplyDrop
                ? "Reordered \(draggedNodeID)."
                : "Unable to reorder dragged node."
        } else {
            didApplyDrop = roleClaimService.moveNode(nodeID: draggedNodeID, newParentID: targetNodeID)
            statusMessage = didApplyDrop
                ? "Moved \(draggedNodeID) under \(targetNodeID)."
                : "Unable to move dragged node."
        }

        guard didApplyDrop else {
            return false
        }

        selectedNodeID = draggedNodeID
        synchronizeSelectionAndTargets()
        return true
    }

    @discardableResult
    func promoteSelectedNode() -> Bool {
        guard showsOrganiserControls else {
            statusMessage = "Only organiser can promote roles."
            return false
        }

        guard let targetNodeID = promoteTargetNodeID else {
            statusMessage = "Select a claimed node to promote."
            return false
        }

        do {
            try roleClaimService.validatePromoteTarget(nodeID: targetNodeID)
        } catch PromoteValidationError.targetUnclaimed {
            statusMessage = "Selected node is not claimed."
            return false
        } catch PromoteValidationError.nodeNotFound {
            statusMessage = "Selected node no longer exists."
            return false
        } catch {
            statusMessage = "Unable to validate promote target."
            return false
        }

        guard roleClaimService.promote(nodeID: targetNodeID) else {
            statusMessage = "Unable to promote selected node."
            return false
        }

        statusMessage = "Promoted \(targetNodeID) to organiser."
        synchronizeSelectionAndTargets()
        return true
    }

    private func synchronizeSelectionAndTargets() {
        guard let tree = roleClaimService.networkConfig?.tree else {
            selectedNodeID = nil
            renameDraft = ""
            promoteTargetNodeID = nil
            return
        }

        if let selectedNodeID,
           let selectedNode = findNode(withID: selectedNodeID, in: tree) {
            renameDraft = selectedNode.label
        } else {
            selectedNodeID = tree.id
            renameDraft = tree.label
        }

        let promotableIDs = Set(promotableNodeRows.map(\.id))
        if promoteTargetNodeID == nil {
            promoteTargetNodeID = promotableNodeRows.first?.id
        } else if let promoteTargetNodeID, !promotableIDs.contains(promoteTargetNodeID) {
            self.promoteTargetNodeID = promotableNodeRows.first?.id
        }
    }

    private func appendRows(from node: TreeNode, depth: Int, into rows: inout [TreeRow]) {
        rows.append(
            TreeRow(
                id: node.id,
                label: node.label,
                depth: depth,
                claimedBy: node.claimedBy
            )
        )

        for child in node.children {
            appendRows(from: child, depth: depth + 1, into: &rows)
        }
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
final class AfterActionReviewViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            refresh()
        }
    }
    @Published private(set) var results: [AfterActionReviewMessage] = []
    @Published private(set) var totalMessageCount: Int = 0

    private let store: any AfterActionReviewPersisting

    init(store: any AfterActionReviewPersisting) {
        self.store = store
        refresh()
    }

    func record(_ message: Message) {
        store.persist(message)
        refresh()
    }

    func refresh() {
        results = store.search(query: query)
        totalMessageCount = store.allMessages().count
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var afterActionReviewViewModel: AfterActionReviewViewModel
    let onReleaseRole: () -> Void

    @State private var isShowingTreeEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                roleSection

                if viewModel.isEditTreeButtonVisible {
                    organiserSection
                } else {
                    GroupBox("Organiser Controls") {
                        Text("Only the organiser can edit tree structure or promote roles.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                afterActionReviewSection

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $isShowingTreeEditor) {
            SettingsTreeEditorView(viewModel: viewModel)
        }
        .accessibilityIdentifier("tacnet.settings.root")
    }

    private var roleSection: some View {
        GroupBox("Role") {
            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.claimedRoleDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Release Role") {
                    if viewModel.releaseRole() {
                        onReleaseRole()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canReleaseRole)
                .accessibilityIdentifier("tacnet.settings.releaseRoleButton")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var organiserSection: some View {
        GroupBox("Organiser Controls") {
            VStack(alignment: .leading, spacing: 10) {
                Button("Edit Tree") {
                    isShowingTreeEditor = true
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isEditTreeButtonDisabled)
                .accessibilityIdentifier("tacnet.settings.editTreeButton")

                if viewModel.promotableNodeRows.isEmpty {
                    Text("No claimed participants available to promote.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Promote Claimed Node", selection: $viewModel.promoteTargetNodeID) {
                        ForEach(viewModel.promotableNodeRows) { row in
                            Text(row.promoteDisplayText)
                                .tag(Optional(row.id))
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Promote") {
                        _ = viewModel.promoteSelectedNode()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canPromoteSelectedNode)
                    .accessibilityIdentifier("tacnet.settings.promoteButton")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var afterActionReviewSection: some View {
        GroupBox("After-Action Review") {
            VStack(alignment: .leading, spacing: 10) {
                NavigationLink {
                    AfterActionReviewView(viewModel: afterActionReviewViewModel)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Search Message History")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(afterActionReviewViewModel.totalMessageCount) stored messages")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tacnet.settings.afterActionReviewLink")

                Text("Search BROADCAST transcripts and COMPACTION summaries with sender, timestamp, type, and GPS metadata.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsTreeEditorView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Tree Nodes") {
                        VStack(alignment: .leading, spacing: 8) {
                            if viewModel.treeRows.isEmpty {
                                Text("No tree is currently available.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.treeRows) { row in
                                    Button {
                                        viewModel.selectNode(row.id)
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(row.displayLabel)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                Text(row.claimedByText)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer(minLength: 8)

                                            if viewModel.selectedNodeID == row.id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.blue)
                                            }
                                        }
                                        .padding(.vertical, 6)
                                        .padding(.leading, CGFloat(row.depth) * 14)
                                    }
                                    .buttonStyle(.plain)
                                    .onDrag {
                                        viewModel.selectNode(row.id)
                                        return NSItemProvider(object: row.id as NSString)
                                    }
                                    .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                        performDrop(providers: providers, targetNodeID: row.id)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Edit Selected Node") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Rename selected node", text: $viewModel.renameDraft)
                                .textFieldStyle(.roundedBorder)

                            HStack(spacing: 10) {
                                Button("Rename") {
                                    _ = viewModel.renameSelectedNode()
                                }
                                .buttonStyle(.bordered)
                                .disabled(!viewModel.canRenameSelectedNode)

                                Button("Remove", role: .destructive) {
                                    _ = viewModel.removeSelectedNode()
                                }
                                .buttonStyle(.bordered)
                                .disabled(!viewModel.canRemoveSelectedNode)
                            }

                            TextField("New child label", text: $viewModel.newChildLabelDraft)
                                .textFieldStyle(.roundedBorder)

                            Button("Add Child") {
                                _ = viewModel.addChildToSelectedNode()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!viewModel.canAddChildNode)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .navigationTitle("Edit Tree")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func performDrop(providers: [NSItemProvider], targetNodeID: String) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }

        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let sourceNodeID = object as? NSString else {
                return
            }
            DispatchQueue.main.async {
                _ = viewModel.handleNodeDrop(draggedNodeID: sourceNodeID as String, onto: targetNodeID)
            }
        }

        return true
    }
}

private struct AfterActionReviewView: View {
    @ObservedObject var viewModel: AfterActionReviewViewModel

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search transcripts and summaries", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                Text(summaryText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if viewModel.results.isEmpty {
                    Text("No matching messages found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ForEach(viewModel.results) { result in
                        AfterActionReviewResultRow(
                            result: result,
                            timestampFormatter: Self.timestampFormatter
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .navigationTitle("After-Action Review")
        .onAppear {
            viewModel.refresh()
        }
        .accessibilityIdentifier("tacnet.afterActionReview.root")
    }

    private var summaryText: String {
        let trimmedQuery = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return "\(viewModel.totalMessageCount) total stored messages."
        }
        return "\(viewModel.results.count) match(es) for “\(trimmedQuery)”."
    }
}

private struct AfterActionReviewResultRow: View {
    let result: AfterActionReviewMessage
    let timestampFormatter: DateFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.senderRole.isEmpty ? result.senderID : result.senderRole)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(timestampFormatter.string(from: result.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(result.type.rawValue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(result.type == .broadcast ? .blue : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (result.type == .broadcast ? Color.blue : Color.orange)
                            .opacity(0.18)
                    )
                    .clipShape(Capsule())
                Text(result.senderID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(result.body.isEmpty ? "(no message body)" : result.body)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(locationText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var locationText: String {
        if result.isFallbackLocation {
            return "GPS unavailable"
        }
        return String(
            format: "GPS %.5f, %.5f (±%.1fm)",
            result.latitude,
            result.longitude,
            result.accuracy
        )
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
    var onBroadcastPublished: ((Message) -> Void)?

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
        onBroadcastPublished?(outboundMessage)
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
    let treeViewModel: TreeViewModel
    let dataFlowViewModel: DataFlowViewModel
    let settingsViewModel: SettingsViewModel
    let afterActionReviewViewModel: AfterActionReviewViewModel

    private var compactionEngine: CompactionEngine?
    private var compactionEngineNodeID: String?
    private var cancellables: Set<AnyCancellable> = []

    init(
        meshService: BluetoothMeshService = BluetoothMeshService(),
        localDeviceID: String = ProcessInfo.processInfo.hostName
    ) {
        self.localDeviceID = localDeviceID
        self.meshService = meshService

        let reviewStore: any AfterActionReviewPersisting
        if #available(iOS 17.0, *) {
            reviewStore = (try? SwiftDataAfterActionReviewStore()) ?? InMemoryAfterActionReviewStore()
        } else {
            reviewStore = InMemoryAfterActionReviewStore()
        }
        afterActionReviewViewModel = AfterActionReviewViewModel(store: reviewStore)

        discoveryService = NetworkDiscoveryService(meshService: meshService)
        treeSyncService = TreeSyncService(
            meshService: meshService,
            configStore: NetworkConfigStore(storageKey: "TacNet.NetworkConfig.Live")
        )
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
        treeViewModel = TreeViewModel(
            roleClaimService: roleClaimService,
            localDeviceID: localDeviceID
        )
        dataFlowViewModel = DataFlowViewModel()
        settingsViewModel = SettingsViewModel(roleClaimService: roleClaimService)
        mainViewModel.onBroadcastPublished = { [weak self] message in
            self?.afterActionReviewViewModel.record(message)
        }

        roleClaimService.$networkConfig
            .combineLatest(roleClaimService.$activeClaimNodeID)
            .receive(on: RunLoop.main)
            .sink { [weak self] config, activeClaimNodeID in
                self?.configureCompactionEngine(
                    networkConfig: config,
                    activeClaimNodeID: activeClaimNodeID
                )
            }
            .store(in: &cancellables)

        configureCompactionEngine(
            networkConfig: roleClaimService.networkConfig,
            activeClaimNodeID: roleClaimService.activeClaimNodeID
        )

        meshService.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                self?.afterActionReviewViewModel.record(message)
                self?.roleClaimService.handleIncomingMessage(message)
                self?.mainViewModel.handleIncomingMessage(message)
                self?.treeViewModel.handleIncomingMessage(message)
                self?.dataFlowViewModel.handleIncomingMessage(message)
                self?.handleCompactionPipeline(for: message)
            }
        }

        meshService.onPeerConnectionStateChanged = { [weak self] peerID, state in
            Task { @MainActor in
                self?.treeSyncService.handlePeerStateChange(peerID: peerID, state: state)
                self?.roleClaimService.handlePeerStateChange(peerID: peerID, state: state)
                self?.mainViewModel.handlePeerConnectionStateChanged(peerID: peerID, state: state)
                self?.treeViewModel.handlePeerConnectionStateChanged(peerID: peerID, state: state)
            }
        }
    }

    func publish(networkConfig: NetworkConfig) {
        let securedConfig = treeSyncService.secureConfigForPublishing(networkConfig)
        treeSyncService.setLocalConfig(securedConfig)
        meshService.publishNetwork(securedConfig)
    }

    func activateRoleClaiming(with config: NetworkConfig) {
        if treeSyncService.localConfig?.networkID != config.networkID {
            treeSyncService.setLocalConfig(config)
        }
        meshService.start()
    }

    private func configureCompactionEngine(
        networkConfig: NetworkConfig?,
        activeClaimNodeID: String?
    ) {
        guard let networkConfig else {
            compactionEngine = nil
            compactionEngineNodeID = nil
            dataFlowViewModel.resetCompactionTelemetry()
            return
        }

        let resolvedLocalNodeID = activeClaimNodeID
            ?? findNodeID(claimedBy: localDeviceID, in: networkConfig.tree)

        guard let resolvedLocalNodeID,
              let localNode = findNode(withID: resolvedLocalNodeID, in: networkConfig.tree) else {
            compactionEngine = nil
            compactionEngineNodeID = nil
            dataFlowViewModel.resetCompactionTelemetry()
            return
        }

        if compactionEngineNodeID == resolvedLocalNodeID,
           let compactionEngine {
            Task {
                await compactionEngine.updateTree(networkConfig.tree)
            }
            return
        }

        let engine = CompactionEngine(
            localDeviceID: localDeviceID,
            localNodeID: resolvedLocalNodeID,
            localSenderRole: localNode.label,
            initialTree: networkConfig.tree
        )
        compactionEngine = engine
        compactionEngineNodeID = resolvedLocalNodeID
        dataFlowViewModel.resetCompactionTelemetry()

        Task {
            await engine.setProcessingObserver { [weak self] metrics in
                Task { @MainActor in
                    self?.dataFlowViewModel.handleProcessingMetrics(metrics)
                }
            }

            await engine.setCompactionEmissionObserver { [weak self] emission in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    self.dataFlowViewModel.handleOutgoingCompaction(emission)
                    self.afterActionReviewViewModel.record(emission.message)
                    self.meshService.publish(emission.message)
                }
            }
        }
    }

    private func handleCompactionPipeline(for message: Message) {
        guard let compactionEngine,
              let tree = roleClaimService.networkConfig?.tree,
              let senderNodeID = resolveSenderNodeID(for: message, in: tree) else {
            return
        }

        switch message.type {
        case .broadcast:
            guard let transcript = message.payload.transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !transcript.isEmpty else {
                return
            }
            Task {
                await compactionEngine.enqueueChildTranscript(transcript, from: senderNodeID)
            }

        case .compaction:
            guard let summary = message.payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty else {
                return
            }
            Task {
                await compactionEngine.enqueueL1CompactionSummary(summary, from: senderNodeID)
            }

        default:
            break
        }
    }

    private func resolveSenderNodeID(for message: Message, in tree: TreeNode) -> String? {
        if TreeHelpers.level(of: message.senderID, in: tree) != nil {
            return message.senderID
        }
        return findNodeID(claimedBy: message.senderID, in: tree)
    }

    private func findNodeID(claimedBy ownerID: String, in tree: TreeNode) -> String? {
        if tree.claimedBy == ownerID {
            return tree.id
        }

        for child in tree.children {
            if let nodeID = findNodeID(claimedBy: ownerID, in: child) {
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
