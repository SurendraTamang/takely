import SwiftUI

@main
struct TakelyApp: App {
    @State private var recorder = RecorderModel()

    var body: some Scene {
        MenuBarExtra {
            RecorderMenu(recorder: recorder)
        } label: {
            MenuBarLabel(recorder: recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let recorder: RecorderModel

    var body: some View {
        switch recorder.phase {
        case .recording, .paused:
            Label(recorder.elapsed.formatted(.time(pattern: .minuteSecond)), systemImage: "record.circle.fill")
                .labelStyle(.titleAndIcon)
        case .exporting:
            Image(systemName: "arrow.down.circle")
        case .idle:
            Image(systemName: "record.circle")
        }
    }
}
