import Foundation

/// JSON-over-HTTP helper shared by the AI providers.
enum AIHTTP {
    static func postJSON(_ url: URL, headers: [String: String] = [:], body: [String: Any], timeout: TimeInterval = 90) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Unreachable servers (e.g. Ollama not running) fail every request.
            throw AIProviderError(message: error.localizedDescription, isFatal: true)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return json }

        let message = errorMessage(in: json) ?? HTTPURLResponse.localizedString(forStatusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        let status = http.statusCode
        switch status {
        case 401, 403:
            throw AIProviderError(message: "The API key was rejected (\(status)): \(message)", isFatal: true)
        case 404:
            throw AIProviderError(message: "Not found (\(status)): \(message). Check the model name.", isFatal: true)
        case 400:
            throw AIProviderError(message: "Request rejected (\(status)): \(message)", isFatal: true)
        default:
            throw AIProviderError(message: "HTTP \(status): \(message)", isFatal: status == 429)
        }
    }

    private static func errorMessage(in json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] { return error["message"] as? String }
        return json["error"] as? String
    }
}

/// Shared prompt and parsing for screenshot descriptions.
enum DescriptionPrompt {
    static let text = """
    You index screenshots so they can be found later with a search box. Look at the screenshot and \
    return a JSON object with two fields:
    - "caption": one or two plain sentences saying what the screenshot shows: the app or website, \
    the main content, and anything distinctive such as names, titles, error messages or numbers.
    - "tags": 5 to 12 short lowercase keywords: app names, topics and the kind of content \
    (for example code, chat, email, chart, design, document, website, terminal, error).
    Write in English. Return only the JSON object.
    """

    /// JSON Schema for providers that support structured output.
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "caption": ["type": "string"],
            "tags": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["caption", "tags"],
        "additionalProperties": false,
    ]

    static func parse(_ text: String) throws -> ScreenshotDescription {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let caption = object["caption"] as? String
        else {
            throw AIProviderError(message: "The model did not return the expected JSON.", isFatal: false)
        }
        var seen = Set<String>()
        let tags = (object["tags"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return ScreenshotDescription(
            caption: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: Array(tags.prefix(15))
        )
    }
}
