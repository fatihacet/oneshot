import Foundation
import OneShotCore

/// Persists the S3 configuration (UserDefaults) and credentials (Keychain).
enum UploadSettings {
    private static let configurationKey = "s3Configuration"

    static var configuration: S3Configuration {
        get {
            guard let data = UserDefaults.standard.data(forKey: configurationKey),
                  let configuration = try? JSONDecoder().decode(S3Configuration.self, from: data)
            else { return S3Configuration() }
            return configuration
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: configurationKey)
        }
    }

    static var accessKeyID: String {
        get { Keychain.string(for: KeychainAccount.s3AccessKeyID) ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: KeychainAccount.s3AccessKeyID) }
    }

    static var secretAccessKey: String {
        get { Keychain.string(for: KeychainAccount.s3SecretAccessKey) ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: KeychainAccount.s3SecretAccessKey) }
    }

    static var credentials: AWSCredentials? {
        let id = accessKeyID
        let secret = secretAccessKey
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return AWSCredentials(accessKeyID: id, secretAccessKey: secret)
    }

    static var isConfigured: Bool { configuration.isComplete && credentials != nil }

    static func client(for configuration: S3Configuration = configuration) throws -> S3Client {
        guard configuration.isComplete, let credentials else {
            throw S3Error.invalidConfiguration("Uploads are not set up yet. Open Settings › Upload.")
        }
        return S3Client(configuration: configuration, credentials: credentials)
    }
}

/// Quick-start values for common S3-compatible providers.
enum StorageProvider: String, CaseIterable, Identifiable {
    case aws
    case cloudflareR2
    case backblazeB2
    case minio
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aws: return "Amazon S3"
        case .cloudflareR2: return "Cloudflare R2"
        case .backblazeB2: return "Backblaze B2"
        case .minio: return "MinIO"
        case .other: return "Other S3-compatible"
        }
    }

    var endpointPlaceholder: String {
        switch self {
        case .aws: return "Leave empty for Amazon S3"
        case .cloudflareR2: return "https://<account-id>.r2.cloudflarestorage.com"
        case .backblazeB2: return "https://s3.<region>.backblazeb2.com"
        case .minio: return "http://localhost:9000"
        case .other: return "https://s3.example.com"
        }
    }

    func apply(to configuration: inout S3Configuration) {
        switch self {
        case .aws:
            configuration.endpoint = ""
            if configuration.region == "auto" { configuration.region = "us-east-1" }
            configuration.usePathStyle = false
        case .cloudflareR2:
            configuration.region = "auto"
            configuration.usePathStyle = true
            configuration.publicReadACL = false
        case .backblazeB2:
            configuration.usePathStyle = false
            configuration.publicReadACL = false
        case .minio:
            if configuration.endpoint.isEmpty { configuration.endpoint = "http://localhost:9000" }
            configuration.region = configuration.region == "auto" ? "us-east-1" : configuration.region
            configuration.usePathStyle = true
        case .other:
            break
        }
    }

    static func guess(for configuration: S3Configuration) -> StorageProvider {
        let endpoint = configuration.endpoint.lowercased()
        if endpoint.isEmpty { return .aws }
        if endpoint.contains("r2.cloudflarestorage.com") { return .cloudflareR2 }
        if endpoint.contains("backblazeb2.com") { return .backblazeB2 }
        if endpoint.contains("localhost") || endpoint.contains(":9000") { return .minio }
        return .other
    }
}
