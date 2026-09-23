import Foundation
import OneShotCore
import Testing

struct FileNamePatternTests {
    private let context = FileNamePattern.Context(
        date: Date(timeIntervalSince1970: 1_790_000_000),
        appName: "Safari",
        pixelSize: CGSize(width: 1280, height: 800)
    )

    @Test func replacesAppAndSizePlaceholders() {
        #expect(FileNamePattern.fileName(pattern: "{app} {width}x{height}", context: context) == "Safari 1280x800")
    }

    @Test func randomHasRequestedLength() {
        #expect(FileNamePattern.fileName(pattern: "{random}", context: context).count == 8)
        #expect(FileNamePattern.fileName(pattern: "{random:12}", context: context).count == 12)
    }

    @Test func keepsUnknownPlaceholdersAndSanitizesSeparators() {
        #expect(FileNamePattern.fileName(pattern: "{nope} a/b:c", context: context) == "{nope} a-b-c")
    }

    @Test func fallsBackToDefaultForEmptyPattern() {
        let name = FileNamePattern.fileName(pattern: "   ", context: context)
        #expect(name.hasPrefix("OneShot "))
    }

    @Test func stripsLeadingDots() {
        #expect(!FileNamePattern.fileName(pattern: "..{app}", context: context).hasPrefix("."))
    }
}
