import Foundation
import OneShotCore
import Testing

/// Test vectors from the AWS documentation ("Signature Calculations for the Authorization Header"
/// and "Authenticating Requests: Using Query Parameters").
struct AWSSigV4Tests {
    private let credentials = AWSCredentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )
    /// 20130524T000000Z
    private let date = Date(timeIntervalSince1970: 1_369_353_600)

    @Test func signsGetObjectExample() throws {
        var request = URLRequest(url: try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")))
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        AWSSigV4.sign(
            &request, credentials: credentials, region: "us-east-1",
            payloadHash: AWSSigV4.emptyPayloadHash, date: date
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == """
        AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, \
        SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, \
        Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41
        """)
    }

    @Test func signsPutObjectExample() throws {
        let payload = Data("Welcome to Amazon S3.".utf8)
        var request = URLRequest(url: try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test%24file.text")))
        request.httpMethod = "PUT"
        request.setValue("Fri, 24 May 2013 00:00:00 GMT", forHTTPHeaderField: "Date")
        request.setValue("REDUCED_REDUNDANCY", forHTTPHeaderField: "x-amz-storage-class")
        AWSSigV4.sign(
            &request, credentials: credentials, region: "us-east-1",
            payloadHash: AWSSigV4.sha256Hex(payload), date: date
        )
        #expect(AWSSigV4.sha256Hex(payload) == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        #expect(request.value(forHTTPHeaderField: "Authorization") == """
        AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, \
        SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, \
        Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd
        """)
    }

    @Test func presignsGetExample() throws {
        let objectURL = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        let url = try #require(AWSSigV4.presignedURL(
            for: objectURL, credentials: credentials, region: "us-east-1", expires: 86400, date: date
        ))
        #expect(url.absoluteString == """
        https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256\
        &X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request\
        &X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host\
        &X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404
        """)
    }

    @Test func uriEncodesLikeAWS() {
        #expect(AWSSigV4.uriEncode("a b/c~d$e") == "a%20b%2Fc~d%24e")
        #expect(AWSSigV4.uriEncode("dir/file name.png", encodeSlash: false) == "dir/file%20name.png")
        #expect(AWSSigV4.uriEncode("ş") == "%C5%9F")
    }
}

struct S3ClientTests {
    private let credentials = AWSCredentials(accessKeyID: "id", secretAccessKey: "secret")

    @Test func buildsVirtualHostedAWSURL() throws {
        let client = S3Client(
            configuration: S3Configuration(region: "eu-central-1", bucket: "shots"),
            credentials: credentials
        )
        #expect(try client.objectURL(for: "a/b c.png").absoluteString
            == "https://shots.s3.eu-central-1.amazonaws.com/a/b%20c.png")
    }

    @Test func usesPathStyleForCustomEndpointsAndDottedBuckets() throws {
        let minio = S3Client(
            configuration: S3Configuration(endpoint: "http://localhost:9000", bucket: "shots", usePathStyle: true),
            credentials: credentials
        )
        #expect(try minio.objectURL(for: "x.png").absoluteString == "http://localhost:9000/shots/x.png")

        let dotted = S3Client(
            configuration: S3Configuration(region: "us-east-1", bucket: "my.bucket"),
            credentials: credentials
        )
        #expect(try dotted.objectURL(for: "x.png").absoluteString == "https://s3.us-east-1.amazonaws.com/my.bucket/x.png")
    }

    @Test func buildsPublicLinkFromCustomDomain() throws {
        let client = S3Client(
            configuration: S3Configuration(
                endpoint: "https://account.r2.cloudflarestorage.com", region: "auto", bucket: "shots",
                usePathStyle: true, publicBaseURL: "shots.example.com/"
            ),
            credentials: credentials
        )
        #expect(try client.link(for: "2026/a b.png").absoluteString == "https://shots.example.com/2026/a%20b.png")
    }

    @Test func presignedLinkContainsSignature() throws {
        let client = S3Client(
            configuration: S3Configuration(bucket: "shots", linkStyle: .presigned, presignExpiry: 3600),
            credentials: credentials
        )
        let link = try client.link(for: "x.png").absoluteString
        #expect(link.contains("X-Amz-Expires=3600"))
        #expect(link.contains("X-Amz-Signature="))
    }

    @Test func joinsKeyPrefix() {
        #expect(S3Configuration(keyPrefix: "/shots").objectKey(for: "a.png") == "shots/a.png")
        #expect(S3Configuration(keyPrefix: "shots/").objectKey(for: "a.png") == "shots/a.png")
        #expect(S3Configuration(keyPrefix: "").objectKey(for: "a.png") == "a.png")
    }

    @Test func reportsMissingBucket() {
        let client = S3Client(configuration: S3Configuration(bucket: " "), credentials: credentials)
        #expect(throws: S3Error.self) { try client.objectURL(for: "a.png") }
    }
}
