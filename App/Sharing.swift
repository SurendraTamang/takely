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

    @discardableResult
    static func write(_ value: String, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

/// Sharing recordings to the user's bucket: the upload in progress, its link, and the setup.
@MainActor @Observable
final class Sharing {
    enum State: Equatable {
        case idle
        case uploading(Double)
        case shared(URL)
        case failed(String)
    }

    private(set) var state = State.idle
    let settings: RecordingSettings
    private let notifier: ReadyNotifier
    private var upload: Task<Void, Never>?
    private let log = Logger(subsystem: "app.takely", category: "share")

    init(settings: RecordingSettings, notifier: ReadyNotifier) {
        self.settings = settings
        self.notifier = notifier
    }

    var isConfigured: Bool { service != nil }

    private var service: ShareService? {
        guard let config = settings.shareBucket, let access = ShareKeychain.read("access-key"), let secret = ShareKeychain.read("secret"),
            !access.isEmpty, !secret.isEmpty
        else { return nil }
        return ShareService(client: S3Client(config: config, accessKey: access, secretKey: secret))
    }

    /// After an export: uploads it when sharing is set up and "Upload after recording" is on.
    func recordingExported(_ export: URL) {
        guard settings.shareAutomatically, isConfigured, let bundle = ProjectBundle.containing(export) else { return }
        share(bundle)
    }

    /// Uploads (or re-uploads, keeping the link), then copies the link and says so.
    func share(_ bundle: ProjectBundle) {
        guard let service else {
            state = .failed(ShareError.notConfigured.localizedDescription)
            return
        }
        guard upload == nil else { return }  // one at a time
        state = .uploading(0)
        upload = Task {
            defer { upload = nil }
            do {
                let link = try await service.share(bundle) { progress in
                    Task { @MainActor [weak self] in
                        if case .uploading = self?.state { self?.state = .uploading(progress) }
                    }
                }
                Self.copy(link)
                state = .shared(link)
                await notifier.linkReady(link, title: (try? bundle.readProject())?.title ?? bundle.name)
            } catch {
                log.error("sharing failed: \(String(describing: error))")
                state = .failed("Upload failed: \(error.localizedDescription)")
                await notifier.recordingFailed("Upload failed: \(error.localizedDescription)")
            }
        }
    }

    func unshare(_ bundle: ProjectBundle) async throws {
        guard let service else { throw ShareError.notConfigured }
        try await service.unshare(bundle)
        state = .idle
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
            TextField("Public URL", text: $publicURL, prompt: Text("https://share.example.com"))
            Text(hint).font(.caption).foregroundStyle(.secondary)
            Toggle("Upload after recording and copy the link", isOn: $settings.shareAutomatically)
            HStack {
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                Button(testing ? "Testing…" : "Test Connection") {
                    save()
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
            "R2: create an API token with Object Read & Write for this bucket. For the public URL, connect a custom domain to the bucket (the r2.dev address is rate-limited). Viewing is free: R2 has no egress fees."
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
        case .other: location = config.endpoint.absoluteString
        }
    }

    private func save() {
        ShareKeychain.write(accessKey.trimmingCharacters(in: .whitespaces), for: "access-key")
        ShareKeychain.write(secret.trimmingCharacters(in: .whitespaces), for: "secret")
        guard let endpoint = BucketConfig.endpoint(for: provider, accountOrRegion: location),
            let base = URL(string: publicURL.trimmingCharacters(in: .whitespaces)), base.scheme == "https" || base.scheme == "http",
            !bucket.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            status = "Fill in the \(locationLabel.lowercased()), the bucket and a public URL starting with https://."
            return
        }
        let region =
            switch provider {
            case .r2: "auto"
            case .s3, .b2: location.trimmingCharacters(in: .whitespaces)
            case .other: "us-east-1"
            }
        sharing.settings.shareBucket = BucketConfig(
            provider: provider, endpoint: endpoint, region: region, bucket: bucket.trimmingCharacters(in: .whitespaces), publicURL: base)
        status = "Saved."
    }
}
