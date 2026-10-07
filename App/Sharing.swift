import AppKit
import OSLog
import Observation
import ProjectKit
import Security
import ShareKit
import SwiftUI

/// The bucket's keys, in the login Keychain (encrypted, tied to this user), never in preferences.
enum ShareKeychain {
    static let service = "app.takely.share"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Updates the item in place (adding it the first time), so a failure never loses the key already saved.
    static func write(_ value: String, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

/// Sharing recordings to the user's bucket: uploads (one at a time, the latest request per recording wins), their
/// links, and taking them down.
@MainActor @Observable
final class Sharing {
    enum State: Equatable {
        case idle
        case uploading(URL, Double)
        case shared(URL, URL)
        case failed(URL, String)

        /// The recording (bundle URL) this is about.
        var bundle: URL? {
            switch self {
            case .idle: nil
            case .uploading(let bundle, _), .shared(let bundle, _), .failed(let bundle, _): bundle
            }
        }
    }

    private(set) var state = State.idle
    let settings: RecordingSettings
    private let notifier: ReadyNotifier
    private var upload: Task<Void, Never>?
    /// A request that came while uploading (a re-export after a blur review…): runs next, replacing older requests.
    private var queued: ProjectBundle?
    /// Read from the Keychain once (and when saved), not on every menu redraw.
    private(set) var credentials: (access: String, secret: String)?
    private let log = Logger(subsystem: "app.takely", category: "share")

    init(settings: RecordingSettings, notifier: ReadyNotifier) {
        self.settings = settings
        self.notifier = notifier
        // Off the main thread: reading keys another build of Takely saved makes macOS ask first (the app mustn't
        // freeze until that's answered).
        initialRead = Task {
            let read = await Task.detached(priority: .userInitiated) { Self.readCredentials() }.value
            guard !Task.isCancelled else { return }  // saved or cleared in Settings meanwhile: that wins
            credentials = read
        }
    }

    /// The launch read of the saved keys (cancelled if they're saved or cleared before it ends).
    private var initialRead: Task<Void, Never>?

    func reloadCredentials() {
        initialRead?.cancel()
        credentials = Self.readCredentials()
    }

    private nonisolated static func readCredentials() -> (access: String, secret: String)? {
        guard let access = ShareKeychain.read("access-key"), let secret = ShareKeychain.read("secret"), !access.isEmpty, !secret.isEmpty
        else { return nil }
        return (access, secret)
    }

    var isConfigured: Bool { settings.shareBucket != nil && credentials != nil }

    private var service: ShareService? {
        guard let config = settings.shareBucket, let credentials else { return nil }
        return ShareService(client: S3Client(config: config, accessKey: credentials.access, secretKey: credentials.secret))
    }

    /// After an export. A recording already shared is updated (its link then shows this version: after a blur
    /// review, the reviewed one). A new one is uploaded when "Upload after recording" is on — unless secrets were
    /// found on screen: the person reviews the blurs first, then shares.
    func recordingExported(_ export: URL) {
        guard isConfigured, let bundle = ProjectBundle.containing(export) else { return }
        if bundle.readShareRecord() != nil { return share(bundle) }
        guard settings.shareAutomatically else { return }
        let blurred = ((try? bundle.readRedactions()) ?? []).contains { $0.enabled && $0.kind != .manual }
        guard !blurred else { return log.info("not uploaded automatically: secrets were blurred, review first") }
        share(bundle)
    }

    /// Uploads (or re-uploads, keeping the link), then copies the link and says so.
    func share(_ bundle: ProjectBundle) {
        guard let service else {
            state = .failed(bundle.url, ShareError.notConfigured.localizedDescription)
            return
        }
        guard upload == nil else {
            queued = bundle
            return
        }
        state = .uploading(bundle.url, 0)
        let includeText = settings.sharePublishText
        upload = Task {
            do {
                let link = try await service.share(bundle, includeText: includeText) { progress in
                    Task { @MainActor [weak self] in
                        if case .uploading(bundle.url, _) = self?.state { self?.state = .uploading(bundle.url, progress) }
                    }
                }
                Self.copy(link)
                state = .shared(bundle.url, link)
                await notifier.linkReady(link, title: (try? bundle.readProject())?.title ?? bundle.name)
            } catch {
                log.error("sharing failed: \(String(describing: error))")
                state = .failed(bundle.url, "Upload failed: \(error.localizedDescription)")
                await notifier.uploadFailed(error.localizedDescription, bundle: bundle)
            }
            upload = nil
            if let next = queued {
                queued = nil
                share(next)
            }
        }
    }

    /// Deletes the shared copy: the link stops working (a CDN may keep cached copies for a while).
    func unshare(_ bundle: ProjectBundle) async {
        guard let service else { return state = .failed(bundle.url, ShareError.notConfigured.localizedDescription) }
        do {
            try await service.unshare(bundle)
            state = .idle
        } catch {
            state = .failed(bundle.url, "Couldn't stop sharing: \(error.localizedDescription)")
        }
    }

    func testConnection() async -> String {
        guard let service else { return "Fill in every field and the keys first." }
        do {
            try await service.testConnection()
            return "Connected: Takely can upload to this bucket."
        } catch {
            return error.localizedDescription
        }
    }

    static func copy(_ link: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
}

/// Settings › Share.
struct ShareSettingsView: View {
    let sharing: Sharing
    @State private var provider = BucketConfig.Provider.r2
    /// R2: the account ID; S3/B2: the region; other: the endpoint URL.
    @State private var location = ""
    @State private var bucket = ""
    @State private var publicURL = ""
    @State private var accessKey = ShareKeychain.read("access-key") ?? ""
    @State private var secret = ShareKeychain.read("secret") ?? ""
    @State private var region = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        @Bindable var settings = sharing.settings
        Form {
            Picker("Storage", selection: $provider) {
                ForEach(BucketConfig.Provider.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            TextField(locationLabel, text: $location, prompt: Text(locationPrompt))
            TextField("Bucket", text: $bucket)
            TextField("Access key ID", text: $accessKey)
            SecureField("Secret access key", text: $secret)
            if provider == .other { TextField("Region", text: $region, prompt: Text("us-east-1")) }
            TextField("Public URL", text: $publicURL, prompt: Text("https://share.example.com"))
            Text(hint).font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: $settings.shareAutomatically) {
                Text("Upload after recording and copy the link")
                Text("Not when secrets were blurred: review the blurs, then use Share Link.")
            }
            Toggle(isOn: $settings.sharePublishText) {
                Text("Show captions, title and summary on the page")
                Text("They come from what was said: turn off if you speak sensitive details.")
            }
            HStack {
                Button("Save") { _ = save() }.keyboardShortcut(.defaultAction)
                Button(testing ? "Testing…" : "Test Connection") {
                    guard save() else { return }
                    testing = true
                    Task {
                        status = await sharing.testConnection()
                        testing = false
                    }
                }
                .disabled(testing)
                Spacer()
            }
            if let status { Text(status).font(.callout) }
        }
        .padding()
        .onAppear(perform: load)
    }

    private var locationLabel: String {
        switch provider {
        case .r2: "Account ID"
        case .s3, .b2: "Region"
        case .other: "Endpoint"
        }
    }

    private var locationPrompt: String {
        switch provider {
        case .r2: "32 characters, in the R2 dashboard"
        case .s3: "us-east-1"
        case .b2: "us-west-004"
        case .other: "https://minio.local:9000"
        }
    }

    private var hint: String {
        switch provider {
        case .r2:
            "R2: create an API token with Object Read & Write for this bucket. For the public URL, connect a custom domain to the bucket (the r2.dev address is rate-limited). Viewing is free: R2 has no egress fees. Recommended: a lifecycle rule that aborts incomplete multipart uploads after 1 day."
        case .s3: "S3: the bucket (or a CloudFront distribution in front of it) must allow public reads of takely/*."
        case .b2: "B2: an application key for this bucket; the bucket must be public."
        case .other: "Any S3-compatible service; objects are addressed path-style."
        }
    }

    private func load() {
        guard let config = sharing.settings.shareBucket else { return }
        provider = config.provider
        bucket = config.bucket
        publicURL = config.publicURL.absoluteString
        switch config.provider {
        case .r2: location = config.endpoint.host()?.components(separatedBy: ".").first ?? ""
        case .s3, .b2: location = config.region
        case .other:
            location = config.endpoint.absoluteString
            region = config.region
        }
    }

    /// Saves the bucket and keys; false (with the reason shown) when something's missing or the Keychain refused.
    private func save() -> Bool {
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let endpoint = BucketConfig.endpoint(for: provider, accountOrRegion: clean(location)),
            let base = URL(string: clean(publicURL)), base.scheme == "https", base.host() != nil, !clean(bucket).isEmpty
        else {
            status = "Fill in the \(locationLabel.lowercased()), the bucket and a public URL starting with https://."
            return false
        }
        guard ShareKeychain.write(clean(accessKey), for: "access-key"), ShareKeychain.write(clean(secret), for: "secret") else {
            status = "Couldn't save the keys in the Keychain."
            return false
        }
        sharing.reloadCredentials()
        let region =
            switch provider {
            case .r2: "auto"
            case .s3, .b2: clean(location)
            case .other: clean(self.region).isEmpty ? "us-east-1" : clean(self.region)
            }
        sharing.settings.shareBucket = BucketConfig(
            provider: provider, endpoint: endpoint, region: region, bucket: clean(bucket), publicURL: base)
        status = "Saved."
        return true
    }

}
