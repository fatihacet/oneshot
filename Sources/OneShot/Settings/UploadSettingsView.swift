import OneShotCore
import SwiftUI

struct UploadSettingsView: View {
    @State private var configuration = UploadSettings.configuration
    @State private var accessKeyID = UploadSettings.accessKeyID
    @State private var secretAccessKey = UploadSettings.secretAccessKey
    @State private var provider = StorageProvider.guess(for: UploadSettings.configuration)
    @State private var testState = TestState.idle

    @AppStorage(PrefKey.uploadAfterCapture) private var uploadAfterCapture = false
    @AppStorage(PrefKey.copyLinkAfterUpload) private var copyLinkAfterUpload = true
    @AppStorage(PrefKey.uploadFileNamePattern) private var fileNamePattern = Preferences.defaultUploadFileNamePattern

    private enum TestState: Equatable {
        case idle
        case running
        case success
        case failure(String)
    }

    private static let expiryChoices: [(title: String, seconds: Int)] = [
        ("1 hour", 3600), ("1 day", 86_400), ("7 days", 604_800),
    ]

    var body: some View {
        Form {
            Section("Storage") {
                Picker("Provider", selection: $provider) {
                    ForEach(StorageProvider.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: provider) { _, newValue in newValue.apply(to: &configuration) }
                TextField("Endpoint", text: $configuration.endpoint, prompt: Text(provider.endpointPlaceholder))
                TextField("Region", text: $configuration.region, prompt: Text("us-east-1"))
                TextField("Bucket", text: $configuration.bucket, prompt: Text("my-screenshots"))
                TextField("Key prefix", text: $configuration.keyPrefix, prompt: Text("screenshots/ (optional)"))
                Toggle("Use path-style URLs", isOn: $configuration.usePathStyle)
            }

            Section {
                TextField("Access key ID", text: $accessKeyID)
                SecureField("Secret access key", text: $secretAccessKey)
            } header: {
                Text("Credentials")
            } footer: {
                Text("Keys are stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Links") {
                Picker("Link type", selection: $configuration.linkStyle) {
                    Text("Public URL").tag(S3Configuration.LinkStyle.publicURL)
                    Text("Presigned URL (private bucket)").tag(S3Configuration.LinkStyle.presigned)
                }
                if configuration.linkStyle == .publicURL {
                    TextField("Custom domain", text: $configuration.publicBaseURL, prompt: Text("https://shots.example.com (optional)"))
                    Toggle("Set public-read ACL on upload", isOn: $configuration.publicReadACL)
                } else {
                    Picker("Links expire after", selection: $configuration.presignExpiry) {
                        ForEach(Self.expiryChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
                    }
                }
                TextField("File name", text: $fileNamePattern, prompt: Text(Preferences.defaultUploadFileNamePattern))
                LabeledContent("Example") {
                    Text(exampleLink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Behavior") {
                Toggle("Copy link to clipboard after upload", isOn: $copyLinkAfterUpload)
                Toggle("Upload automatically after every capture", isOn: $uploadAfterCapture)
                    .disabled(!isConfigured)
            }

            Section {
                HStack {
                    Button("Test Connection", action: testConnection)
                        .disabled(!isConfigured || testState == .running)
                    testStatus
                    Spacer()
                    Button("Upload History…") { UploadHistoryWindowController.shared.show() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: configuration) { _, newValue in
            UploadSettings.configuration = newValue
            testState = .idle
        }
        .onChange(of: accessKeyID) { _, newValue in
            UploadSettings.accessKeyID = newValue
            testState = .idle
        }
        .onChange(of: secretAccessKey) { _, newValue in
            UploadSettings.secretAccessKey = newValue
            testState = .idle
        }
    }

    private var isConfigured: Bool {
        configuration.isComplete && !accessKeyID.isEmpty && !secretAccessKey.isEmpty
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        }
    }

    private var exampleLink: String {
        let name = FileNamePattern.fileName(pattern: fileNamePattern, context: .init(appName: "Safari"))
        let key = configuration.objectKey(for: "\(name).\(Preferences.imageFormat.fileExtension)")
        let client = S3Client(configuration: configuration, credentials: AWSCredentials(accessKeyID: "", secretAccessKey: ""))
        switch configuration.linkStyle {
        case .publicURL:
            return (try? client.link(for: key).absoluteString) ?? "Enter a bucket to see an example"
        case .presigned:
            guard let url = try? client.objectURL(for: key) else { return "Enter a bucket to see an example" }
            return url.absoluteString + "?X-Amz-Signature=…"
        }
    }

    private func testConnection() {
        testState = .running
        let configuration = configuration
        let credentials = AWSCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
        Task {
            do {
                try await Uploader.testConnection(configuration: configuration, credentials: credentials)
                testState = .success
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
