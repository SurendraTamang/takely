import SwiftUI

/// First-launch welcome: where Takely lives, the hotkeys, and the permissions.
struct OnboardingView: View {
    let permissions: Permissions
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Takely").font(.largeTitle.bold())
            Text(
                "Takely lives in your menu bar. If you can't see its icon (it can hide behind the notch), press **⌥⇧T** anytime to open it, and **⌥⇧R** to start or stop recording."
            )
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            PermissionRows(permissions: permissions)
            Text("Local builds: after rebuilding Takely, macOS may ask you to allow Screen Recording again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
