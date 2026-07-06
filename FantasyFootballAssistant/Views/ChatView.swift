import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// Follow-up chat with the AI advisor, embedded permanently in the lower half
// of the Advisor panel (not a sheet) so it's always visible. Every question
// is sent with the same rich draft context as the one-shot advisor (rebuilt
// fresh each time, since the roster/board change between questions) plus the
// running conversation.
struct ChatPanel: View {
    let session: DraftSession
    @State private var draft = ""

    private var isBusy: Bool {
        switch session.chatState {
        case .syncing, .loading: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right").font(.caption)
            Text("CHAT").font(.system(size: 11, weight: .bold)).kerning(0.6)
            Spacer()
            Button("Log") { revealLogFile() }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                .help("Open the AI request/response log in Finder — for troubleshooting")
            Button("Clear") { session.clearChat() }
                .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                .disabled(session.chatMessages.isEmpty && !isBusy)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if session.chatMessages.isEmpty {
                        Text("Ask a follow-up — e.g. \"Should I reach for a QB now or wait?\" Full roster/board context is included automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(session.chatMessages) { message in
                        bubble(message).id(message.id)
                    }
                    // The answer bubble builds up token-by-token as it streams
                    // in, rather than sitting behind a static spinner.
                    if isBusy, !session.chatStreamText.isEmpty {
                        streamingBubble.id("streaming")
                    }
                    if isBusy {
                        busyRow.id("busy")
                    }
                }
                .padding(10)
            }
            .onChange(of: session.chatMessages.count) {
                withAnimation { proxy.scrollTo(session.chatMessages.last?.id, anchor: .bottom) }
            }
            .onChange(of: isBusy) {
                if isBusy { withAnimation { proxy.scrollTo("busy", anchor: .bottom) } }
            }
            .onChange(of: session.chatStreamText) {
                proxy.scrollTo("busy", anchor: .bottom)
            }
        }
    }

    private var streamingBubble: some View {
        HStack {
            Text(session.chatStreamText + "▌")
                .font(.callout)
                .padding(8)
                .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 24)
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        let isError = message.role == .error
        return HStack {
            if isUser { Spacer(minLength: 24) }
            Text(message.text)
                .font(.callout)
                .foregroundStyle(isError ? Color.red : Color.primary)
                .padding(8)
                .background(
                    isUser ? Color.accentColor.opacity(0.18)
                        : isError ? Color.red.opacity(0.1)
                        : Color.gray.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            if !isUser { Spacer(minLength: 24) }
        }
    }

    private var busyRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(busyLabel).font(.caption).foregroundStyle(.secondary)
            if let started = session.chatStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(started)))s")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Button("Stop") { session.cancelChat() }
                .controlSize(.small)
        }
        .padding(.trailing, 24)
    }

    private var busyLabel: String {
        if case .syncing = session.chatState { return "Syncing latest picks…" }
        return "Thinking…"
    }

    private var composer: some View {
        HStack {
            TextField("Ask a question…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit(send)
            Button("Send") { send() }
                .disabled(isBusy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
    }

    private func send() {
        let text = draft
        draft = ""
        session.sendChatMessage(text)
    }

    private func revealLogFile() {
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([AILogger.logFileURL])
        #endif
    }
}
