import SwiftUI

/// One row per permission with live status and a Grant button; shared by onboarding and Settings.
struct PermissionRows: View {
    let permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Permissions.Kind.allCases) { kind in row(kind) }
        }
        .task {
            // Grants happen in System Settings, so poll while this is on screen.
            while !Task.isCancelled {
                await permissions.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ kind: Permissions.Kind) -> some View {
        HStack(alignment: .top) {
            Image(systemName: permissions.granted[kind] == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(permissions.granted[kind] == true ? .green : .secondary)
                .accessibilityLabel(permissions.granted[kind] == true ? "Granted" : "Not granted")
            VStack(alignment: .leading) {
                Text(kind.title).font(.headline)
                Text(kind.purpose).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if permissions.granted[kind] != true {
                Button("Grant") { Task { await permissions.request(kind) } }
            }
        }
    }
}
