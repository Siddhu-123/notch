import Foundation
import Testing
@testable import notch

struct ClipboardFeatureTests {
    @Test func sensitiveTextRequiresLengthAndThreeCharacterClasses() {
        #expect(!SensitiveText.isLikelySecret(String(repeating: "a", count: 8) + "1!A"))
        #expect(SensitiveText.isLikelySecret(String(repeating: "a", count: 9) + "1!A"))
        #expect(SensitiveText.isLikelySecret("abcdefghij1!"))
        #expect(SensitiveText.isLikelySecret("Abcdefghi1!Z"))
        #expect(!SensitiveText.isLikelySecret("abcdefghij12"))
        #expect(SensitiveText.isLikelySecret(String(repeating: "a", count: 125) + "1!A"))
        #expect(!SensitiveText.isLikelySecret(String(repeating: "a", count: 126) + "1!A"))
    }

    @Test func sensitiveTextRejectsWhitespaceURLsAndPaths() {
        #expect(!SensitiveText.isLikelySecret("Abcdefghij 1!"))
        #expect(!SensitiveText.isLikelySecret("https://example.com/Abcdefgh1!"))
        #expect(!SensitiveText.isLikelySecret("https:example.com/Abcdefgh1!"))
        #expect(!SensitiveText.isLikelySecret("example.com?q=Abcdefgh1!"))
        #expect(!SensitiveText.isLikelySecret("person@example.com"))
        #expect(!SensitiveText.isLikelySecret("2001:db8::1a2B"))
        #expect(!SensitiveText.isLikelySecret("/Users/sid/Abcdefgh1!"))
        #expect(!SensitiveText.isLikelySecret("C:\\Users\\sid\\Abcdefgh1!"))
    }

    @Test func sensitiveClipboardRecognizesConcealedTypesAndTextHeuristics() {
        #expect(ClipboardSensitivity.isSensitive(types: ["org.nspasteboard.ConcealedType"], text: nil))
        #expect(ClipboardSensitivity.isSensitive(types: ["org.nspasteboard.TransientType"], text: "ordinary text"))
        #expect(ClipboardSensitivity.isSensitive(types: [], text: "Abcdefghij1!"))
        #expect(!ClipboardSensitivity.isSensitive(types: ["public.utf8-plain-text"], text: "ordinary text"))
    }

    @Test func autoClearRequiresSameClipboardAndElapsedDelay() {
        #expect(!ClipboardAutoClearPolicy.shouldClear(
            capturedChangeCount: 4, currentChangeCount: 4, elapsed: 29.9, delay: 30
        ))
        #expect(ClipboardAutoClearPolicy.shouldClear(
            capturedChangeCount: 4, currentChangeCount: 4, elapsed: 30, delay: 30
        ))
        #expect(ClipboardAutoClearPolicy.shouldClear(
            capturedChangeCount: 4, currentChangeCount: 4, elapsed: 45, delay: 30
        ))
        #expect(!ClipboardAutoClearPolicy.shouldClear(
            capturedChangeCount: 4, currentChangeCount: 5, elapsed: 60, delay: 30
        ))
        #expect(!ClipboardAutoClearPolicy.shouldClear(
            capturedChangeCount: 4, currentChangeCount: 4, elapsed: -1, delay: 30
        ))
        #expect(!ClipboardAutoClearPolicy.shouldClear(
            capturedChangeCount: 4, currentChangeCount: 4, elapsed: 30, delay: 0
        ))
    }
}
