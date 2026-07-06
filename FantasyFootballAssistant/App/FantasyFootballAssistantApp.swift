import SwiftUI

@main
struct FantasyFootballAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1080, minHeight: 640)
        }
    }
}

struct ContentView: View {
    @State private var session: DraftSession?

    var body: some View {
        if let session {
            DraftView(session: session) {
                session.stop()
                self.session = nil
            }
        } else {
            SetupView { newSession in
                session = newSession
                newSession.startPolling()
            }
        }
    }
}
