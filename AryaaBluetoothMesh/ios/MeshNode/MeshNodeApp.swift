import SwiftUI

@main
struct MeshNodeApp: App {
    @StateObject private var mesh = MeshManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mesh)
                .onAppear { mesh.start() }
        }
    }
}
