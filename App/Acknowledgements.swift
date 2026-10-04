import AppKit
import SwiftUI

/// The third-party components in Takely and their licenses (bundled `NOTICE` and `Licenses/`), as their licenses
/// require when the app is distributed.
@MainActor
enum Acknowledgements {
    private static var window: NSWindow?

    static func show() {
        let window =
            window
            ?? {
                let window = NSWindow(contentViewController: NSHostingController(rootView: AcknowledgementsView(text: text)))
                window.title = "Acknowledgements"
                window.styleMask = [.titled, .closable, .resizable]
                window.isReleasedWhenClosed = false
                window.setContentSize(NSSize(width: 640, height: 560))
                window.center()
                return window
            }()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    static var text: String {
        var parts: [String] = []
        if let notice = Bundle.main.url(forResource: "NOTICE", withExtension: nil),
            let text = try? String(contentsOf: notice, encoding: .utf8)
        {
            parts.append(text)
        }
        if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
            let text = try? String(contentsOf: license, encoding: .utf8)
        {
            parts.append("── Takely (open-source parts): GNU Affero General Public License v3.0 ──\n\n\(text)")
        }
        if let folder = Bundle.main.url(forResource: "Licenses", withExtension: nil),
            let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                parts.append("── \(file.deletingPathExtension().lastPathComponent) ──\n\n\(text)")
            }
        }
        return parts.isEmpty ? "The license texts are missing from this build." : parts.joined(separator: "\n\n")
    }
}

private struct AcknowledgementsView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
