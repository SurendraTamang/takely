#if canImport(TakelyPro)
    import AppCore
    import AppKit
    import SwiftUI
    import TakelyPro

    /// Settings › License (Takely Pro builds): the trial or license, entering a key, freeing this Mac, buying.
    struct LicenseView: View {
        let license: LicenseManager
        @State private var key = ""
        @State private var working = false
        @State private var message: String?

        var body: some View {
            Form {
                LabeledContent("Status") {
                    switch license.state {
                    case .trial(let days): Text("Free trial: \(days) day\(days == 1 ? "" : "s") left")
                    case .licensed(let product): Text("\(product) — active on this Mac")
                    case .locked(let reason): Text(reason).foregroundStyle(.red)
                    }
                }
                if license.hasKey {
                    HStack {
                        Button(working ? "Working…" : "Check Again") { run { await license.refresh(force: true) } }
                            .disabled(working)
                        Button("Deactivate on This Mac") { run { try await license.deactivate() } }
                            .disabled(working)
                    }
                    Text("Frees this Mac's activation so you can use the key on another Mac.").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("License key", text: $key, prompt: Text("From your purchase email"))
                    HStack {
                        Button(working ? "Activating…" : "Activate") { run { try await license.activate(key) } }
                            .disabled(working || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.defaultAction)
                        if let buy = license.config.buyURL {
                            Button("Buy Takely Pro") { NSWorkspace.shared.open(buy) }
                        }
                    }
                }
                if let message { Text(message).font(.callout) }
                Text(
                    "Takely Pro: transcripts and captions, AI titles and summaries, the editor, blurring secrets automatically, the voice-following prompter and coach, Demo Mode. Everything else is free."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }

        private func run(_ work: @escaping () async throws -> Void) {
            working = true
            message = nil
            Task {
                defer { working = false }
                do {
                    try await work()
                    key = ""
                    message = license.state.unlocksPro ? "Done." : nil
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }

    enum ProUnlock {
        /// Before a Pro action: true when Pro is available; otherwise offers to unlock it.
        @MainActor static func allowed(_ license: LicenseManager, openSettings: () -> Void) -> Bool {
            guard !ProAccess.isUnlocked else { return true }
            let alert = NSAlert()
            alert.messageText = "This is a Takely Pro feature"
            let reason = if case .locked(let reason) = license.state { reason } else { "" }
            alert.informativeText = "\(reason) Enter a license key, or buy Takely Pro, in Settings › License."
            alert.addButton(withTitle: "Open License Settings")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { openSettings() }
            return false
        }
    }
#endif
