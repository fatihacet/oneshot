import Foundation

/// Connection settings for an S3-compatible bucket.
public struct S3Configuration: Codable, Equatable, Sendable {
    public enum LinkStyle: String, Codable, CaseIterable, Sendable {
        /// A permanent URL; the bucket (or CDN) must allow public reads.
        case publicURL
        /// A time-limited presigned URL; works with private buckets.
        case presigned
    }

    /// Custom endpoint such as `https://<account>.r2.cloudflarestorage.com` or `http://localhost:9000`.
    /// Empty means Amazon S3 in `region`.
    public var endpoint: String
    public var region: String
    public var bucket: String
    /// Prepended to every object key, e.g. `screenshots/`.
    public var keyPrefix: String
    /// Path-style URLs (`endpoint/bucket/key`), required by MinIO and handy for R2.
    public var usePathStyle: Bool
    /// Optional custom domain or CDN, e.g. `https://shots.example.com`. Used for public links.
    public var publicBaseURL: String
    public var linkStyle: LinkStyle
    /// Lifetime of presigned links in seconds (S3 allows up to 7 days).
    public var presignExpiry: Int
    /// Sends `x-amz-acl: public-read`. Only for buckets that use ACLs (not R2).
    public var publicReadACL: Bool

    public init(
        endpoint: String = "",
        region: String = "us-east-1",
        bucket: String = "",
        keyPrefix: String = "",
        usePathStyle: Bool = false,
        publicBaseURL: String = "",
        linkStyle: LinkStyle = .publicURL,
        presignExpiry: Int = 7 * 24 * 3600,
        publicReadACL: Bool = false
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.keyPrefix = keyPrefix
        self.usePathStyle = usePathStyle
        self.publicBaseURL = publicBaseURL
        self.linkStyle = linkStyle
        self.presignExpiry = presignExpiry
        self.publicReadACL = publicReadACL
    }

    public var isComplete: Bool {
        !bucket.trimmingCharacters(in: .whitespaces).isEmpty && !region.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Joins the prefix and a file name into an object key.
    public func objectKey(for fileName: String) -> String {
        var prefix = keyPrefix.trimmingCharacters(in: .whitespaces)
        while prefix.hasPrefix("/") { prefix.removeFirst() }
        if !prefix.isEmpty, !prefix.hasSuffix("/") { prefix += "/" }
        return prefix + fileName
    }
}

public enum S3Error: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case http(status: Int, code: String?, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return reason
        case .http(let status, let code, let message):
            let detail = [code, message].compactMap { $0 }.joined(separator: ": ")
            return detail.isEmpty ? "HTTP \(status)" : "HTTP \(status) – \(detail)"
        }
    }
}

/// Minimal S3 client: PUT and DELETE objects, and build public or presigned links.
public struct S3Client: Sendable {
    public let configuration: S3Configuration
    public let credentials: AWSCredentials
    private let session: URLSession

    public init(configuration: S3Configuration, credentials: AWSCredentials, session: URLSession = .shared) {
        self.configuration = configuration
        self.credentials = credentials
        self.session = session
    }

    /// The canonical request URL of an object.
    public func objectURL(for key: String) throws -> URL {
        let bucket = configuration.bucket.trimmingCharacters(in: .whitespaces)
        guard !bucket.isEmpty else { throw S3Error.invalidConfiguration("Bucket name is missing.") }

        var components: URLComponents
        let endpoint = configuration.endpoint.trimmingCharacters(in: .whitespaces)
        if endpoint.isEmpty {
            components = URLComponents()
            components.scheme = "https"
            components.host = "s3.\(configuration.region).amazonaws.com"
        } else {
            let withScheme = endpoint.contains("://") ? endpoint : "https://\(endpoint)"
            guard let parsed = URLComponents(string: withScheme), parsed.host != nil else {
                throw S3Error.invalidConfiguration("Endpoint URL is invalid.")
            }
            components = parsed
        }

        let encodedKey = AWSSigV4.uriEncode(key, encodeSlash: false)
        // Buckets with dots break TLS for virtual-hosted URLs, so they always use path style.
        if configuration.usePathStyle || bucket.contains(".") {
            let basePath = components.percentEncodedPath.hasSuffix("/")
                ? String(components.percentEncodedPath.dropLast())
                : components.percentEncodedPath
            components.percentEncodedPath = "\(basePath)/\(AWSSigV4.uriEncode(bucket))/\(encodedKey)"
        } else {
            components.host = "\(bucket).\(components.host ?? "")"
            components.percentEncodedPath = "/\(encodedKey)"
        }
        components.query = nil
        guard let url = components.url else { throw S3Error.invalidConfiguration("Could not build the object URL.") }
        return url
    }

    /// The link to share for an uploaded object, following `linkStyle`.
    public func link(for key: String, date: Date = Date()) throws -> URL {
        switch configuration.linkStyle {
        case .presigned:
            let expiry = min(max(configuration.presignExpiry, 1), 7 * 24 * 3600)
            guard let url = AWSSigV4.presignedURL(
                for: try objectURL(for: key), credentials: credentials,
                region: configuration.region, expires: expiry, date: date
            ) else { throw S3Error.invalidConfiguration("Could not presign the URL.") }
            return url
        case .publicURL:
            var base = configuration.publicBaseURL.trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty else { return try objectURL(for: key) }
            if !base.contains("://") { base = "https://\(base)" }
            while base.hasSuffix("/") { base.removeLast() }
            guard let url = URL(string: "\(base)/\(AWSSigV4.uriEncode(key, encodeSlash: false))") else {
                throw S3Error.invalidConfiguration("Public base URL is invalid.")
            }
            return url
        }
    }

    /// Uploads `data` to `key`. `progress` receives values from 0 to 1.
    public func putObject(
        key: String,
        data: Data,
        contentType: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: try objectURL(for: key))
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if configuration.publicReadACL {
            request.setValue("public-read", forHTTPHeaderField: "x-amz-acl")
        }
        AWSSigV4.sign(
            &request, credentials: credentials, region: configuration.region,
            payloadHash: AWSSigV4.sha256Hex(data)
        )
        let delegate = progress.map(UploadProgressDelegate.init)
        let (body, response) = try await session.upload(for: request, from: data, delegate: delegate)
        try Self.validate(response, body: body)
    }

    public func deleteObject(key: String) async throws {
        var request = URLRequest(url: try objectURL(for: key))
        request.httpMethod = "DELETE"
        AWSSigV4.sign(
            &request, credentials: credentials, region: configuration.region,
            payloadHash: AWSSigV4.emptyPayloadHash
        )
        let (body, response) = try await session.data(for: request)
        try Self.validate(response, body: body)
    }

    private static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let xml = String(data: body, encoding: .utf8) ?? ""
            throw S3Error.http(
                status: http.statusCode,
                code: xmlValue("Code", in: xml),
                message: xmlValue("Message", in: xml)
            )
        }
    }

    private static func xmlValue(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void

    init(_ handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        handler(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
