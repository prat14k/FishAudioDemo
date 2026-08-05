import SwiftUI
import UniformTypeIdentifiers

struct TranscriptWindowView: View {
    @ObservedObject private var transcriber = CallTranscriber.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live Call Transcript").font(.headline)
                Spacer()
                Button(transcriber.isRunning ? "Stop" : "Start") {
                    if transcriber.isRunning { transcriber.stop() } else { transcriber.start() }
                }
                Button("Save…") { save() }
                    .disabled(transcriber.lines.isEmpty)
                Button("Clear") { transcriber.clear() }
                    .disabled(transcriber.lines.isEmpty || transcriber.isRunning)
            }

            Text("Captures system audio (what you hear) — not your own mic. First run prompts for Screen Recording permission in System Settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !transcriber.statusText.isEmpty {
                Text(transcriber.statusText).font(.caption).foregroundStyle(.orange)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(transcriber.lines) { line in
                            Text(line.text).id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: transcriber.lines.count) { _, _ in
                    if let last = transcriber.lines.last {
                        withAnimation { proxy.scrollTo(last.id) }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 320)
        // Closing the window must end the capture — otherwise system audio keeps being
        // recorded and sent to the API with nothing on screen to show it. The transcript
        // itself is kept (CallTranscriber is shared) so it can still be saved on reopen.
        .onDisappear { transcriber.stop() }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? transcriber.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
