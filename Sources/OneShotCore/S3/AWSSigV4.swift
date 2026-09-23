import CryptoKit
import Foundation

public struct AWSCredentials: Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

/// AWS Signature Version 4 for S3 and S3-compatible services.
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html
public enum AWSSigV4 {
    public static let algorithm = "AWS4-HMAC-SHA256"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"
    public static let emptyPayloadHash = sha256Hex(Data())

    /// Adds `x-amz-date`, `x-amz-content-sha256` and `Authorization` headers to `request`.
    /// The URL's path must already be percent-encoded with `uriEncode(_:encodeSlash: false)`.
    public static func sign(
        _ request: inout URLRequest,
        credentials: AWSCredentials,
        region: String,
        service: String = "s3",
        payloadHash: String,
        date: Date = Date()
    ) {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }
        let (amzDate, dateStamp) = timestamps(for: date)
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        var headers: [String: String] = ["host": hostHeader(for: components)]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        let sortedNames = headers.keys.sorted()
        let canonicalHeaders = sortedNames.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = sortedNames.joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalPath(components),
            canonicalQuery(components.percentEncodedQueryItems ?? []),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let signature = self.signature(
            canonicalRequest: canonicalRequest, amzDate: amzDate, dateStamp: dateStamp,
            scope: scope, region: region, service: service, secret: credentials.secretAccessKey
        )
        request.setValue(
            "\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    /// Returns a presigned URL (query string authentication) valid for `expires` seconds.
    public static func presignedURL(
        for url: URL,
        method: String = "GET",
        credentials: AWSCredentials,
        region: String,
        service: String = "s3",
        expires: Int,
        date: Date = Date()
    ) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let (amzDate, dateStamp) = timestamps(for: date)
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"

        var items = components.percentEncodedQueryItems ?? []
        items += [
            URLQueryItem(name: "X-Amz-Algorithm", value: algorithm),
            URLQueryItem(name: "X-Amz-Credential", value: uriEncode("\(credentials.accessKeyID)/\(scope)")),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(expires)),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]
        let query = canonicalQuery(items)

        let canonicalRequest = [
            method,
            canonicalPath(components),
            query,
            "host:\(hostHeader(for: components))\n",
            "host",
            unsignedPayload,
        ].joined(separator: "\n")

        let signature = self.signature(
            canonicalRequest: canonicalRequest, amzDate: amzDate, dateStamp: dateStamp,
            scope: scope, region: region, service: service, secret: credentials.secretAccessKey
        )
        components.percentEncodedQuery = query + "&X-Amz-Signature=" + signature
        return components.url
    }

    /// URI-encodes per AWS rules: everything except `A-Z a-z 0-9 - . _ ~` (and `/` when kept).
    public static func uriEncode(_ string: String, encodeSlash: Bool = true) -> String {
        var result = ""
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: "/") where !encodeSlash:
                result.append("/")
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Helpers

    private static func signature(
        canonicalRequest: String, amzDate: String, dateStamp: String, scope: String,
        region: String, service: String, secret: String
    ) -> String {
        let stringToSign = [
            algorithm,
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func timestamps(for date: Date) -> (amzDate: String, dateStamp: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = formatter.string(from: date)
        return (amzDate, String(amzDate.prefix(8)))
    }

    private static func hostHeader(for components: URLComponents) -> String {
        let host = components.percentEncodedHost ?? ""
        guard let port = components.port else { return host }
        let isDefault = (components.scheme == "https" && port == 443) || (components.scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }

    private static func canonicalPath(_ components: URLComponents) -> String {
        let path = components.percentEncodedPath
        return path.isEmpty ? "/" : path
    }

    /// Query items must already be percent-encoded (as returned by `percentEncodedQueryItems`).
    private static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        // Normalize: decode, then re-encode with AWS rules.
        var pairs: [(name: String, value: String)] = []
        for item in items {
            let rawName = item.name.removingPercentEncoding ?? item.name
            let rawValue = item.value.map { $0.removingPercentEncoding ?? $0 } ?? ""
            pairs.append((uriEncode(rawName), uriEncode(rawValue)))
        }
        pairs.sort { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }
}
