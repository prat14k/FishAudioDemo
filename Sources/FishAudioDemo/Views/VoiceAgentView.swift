import SwiftUI

struct VoiceAgentView: View {
    @StateObject private var session = VoiceAgentSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Talk to the Agent").font(.subheadline.bold())
            Text(statusText).font(.caption).foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(session.log.indices, id: \.self) { i in
                            Text(session.log[i]).font(.caption).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .onChange(of: session.log.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1) }
                }
            }

            Button(session.isRunning ? "Stop" : "Start Talking") {
                if session.isRunning { session.stop() } else { session.start() }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Tap Start and speak."
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        case .error(let msg): return msg
        }
    }
}
