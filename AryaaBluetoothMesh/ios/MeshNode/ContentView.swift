import SwiftUI

struct ContentView: View {
    @EnvironmentObject var mesh: MeshManager
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                debugBar
                Divider()
                messageList
                Divider()
                composer
            }
            .navigationTitle("MeshNode")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var debugBar: some View {
        HStack(spacing: 8) {
            stat("Peers", mesh.connectedPeerCount)
            stat("Sent",  mesh.sentCount)
            stat("Recv",  mesh.receivedCount)
            stat("Fwd",   mesh.forwardedCount)
            stat("Dedup", mesh.dedupedCount)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text("\(value)").bold()
        }
        .frame(maxWidth: .infinity)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(mesh.messages) { msg in
                        messageRow(msg)
                            .id(msg.id)
                    }
                }
                .padding()
            }
            .onChange(of: mesh.messages.count) { _, _ in
                if let last = mesh.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func messageRow(_ msg: MeshMessage) -> some View {
        let isSelf = msg.senderId == mesh.selfId
        return HStack {
            if isSelf { Spacer() }
            VStack(alignment: isSelf ? .trailing : .leading, spacing: 2) {
                Text(msg.payload)
                    .padding(8)
                    .background(isSelf ? Color.accentColor.opacity(0.2)
                                       : Color(uiColor: .systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("\(shortId(msg.senderId)) · TTL \(msg.ttl)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isSelf { Spacer() }
        }
    }

    private var composer: some View {
        HStack {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .submitLabel(.send)
                .onSubmit(sendDraft)
            Button("Send", action: sendDraft)
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private func sendDraft() {
        mesh.send(text: draft)
        draft = ""
    }

    private func shortId(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}

#Preview {
    ContentView().environmentObject(MeshManager())
}
