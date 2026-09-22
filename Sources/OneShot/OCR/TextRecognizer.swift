import AppKit
import Vision

/// On-device text and barcode recognition using Apple's Vision framework.
enum TextRecognizer {
    enum Result {
        case barcode(String)
        case text(String)
        case nothing
    }

    static func recognize(_ image: CGImage, keepLineBreaks: Bool) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            let barcodeRequest = VNDetectBarcodesRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true

            try handler.perform([barcodeRequest, textRequest])

            if let payload = barcodeRequest.results?.compactMap(\.payloadStringValue).first, !payload.isEmpty {
                return .barcode(payload)
            }
            let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            guard !lines.isEmpty else { return .nothing }
            return .text(lines.joined(separator: keepLineBreaks ? "\n" : " "))
        }.value
    }

    /// Recognizes text (or a QR code / barcode) and copies it to the clipboard with feedback.
    @MainActor
    static func recognizeAndCopy(_ image: CGImage) {
        Task {
            do {
                let result = try await recognize(image, keepLineBreaks: Preferences.ocrKeepLineBreaks)
                switch result {
                case .barcode(let payload):
                    copy(payload)
                    Toast.show("Copied code: \(payload.prefix(60))", symbol: "qrcode")
                case .text(let text):
                    copy(text)
                    Toast.show("Copied \(text.count) characters", symbol: "text.viewfinder")
                case .nothing:
                    Toast.show("No text found", symbol: "text.magnifyingglass")
                }
            } catch {
                Toast.show("Text recognition failed", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
