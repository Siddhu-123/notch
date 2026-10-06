import Testing
@testable import notch

struct MusicExtrasTests {
    @Test func lyricsParserReadsLRCBoundariesAndFractions() {
        let lines = LyricsParser.parse("""
        [00:00.00]Zero
        [00:59.99]Last second
        [01:00.00]Next minute
        [02:03.1]One decimal
        [02:03.12]Two decimals
        [02:03.123]Three decimals
        """)

        #expect(lines.map(\.text) == ["Zero", "Last second", "Next minute", "One decimal", "Two decimals", "Three decimals"])
        let expected = [0.0, 59.99, 60, 123.1, 123.12, 123.123]
        #expect(zip(lines.map(\.time), expected).allSatisfy { abs($0 - $1) < 0.0001 })
    }

    @Test func lyricsParserSortsAndExpandsRepeatedTimestamps() {
        let lines = LyricsParser.parse("""
        [00:04.00][00:02.00]Repeated
        [00:03.50]Middle
        """)

        #expect(lines == [
            LyricLine(time: 2, text: "Repeated"),
            LyricLine(time: 3.5, text: "Middle"),
            LyricLine(time: 4, text: "Repeated")
        ])
    }

    @Test func lyricsParserSkipsMalformedEmptyAndUntaggedLines() {
        let lines = LyricsParser.parse("""
        Plain text
        [00:60.00]Invalid seconds
        [00:12.00]
        [00:12.00]  Kept line  
        [offset:+100]Metadata
        [1000:12.00]Too many minute digits
        """)

        #expect(lines == [LyricLine(time: 12, text: "Kept line")])
    }

    @Test func lyricsCurrentLineUsesInclusiveTimestampBoundaries() {
        let lines = [
            LyricLine(time: 10, text: "First"),
            LyricLine(time: 20, text: "Second")
        ]

        #expect(LyricsParser.currentLineIndex(in: lines, at: -0.01) == nil)
        #expect(LyricsParser.currentLineIndex(in: lines, at: 0) == nil)
        #expect(LyricsParser.currentLineIndex(in: lines, at: 9.99) == nil)
        #expect(LyricsParser.currentLineIndex(in: lines, at: 10) == 0)
        #expect(LyricsParser.currentLineIndex(in: lines, at: 19.99) == 0)
        #expect(LyricsParser.currentLineIndex(in: lines, at: 20) == 1)
        #expect(LyricsParser.currentLineIndex(in: lines, at: 90) == 1)
        #expect(LyricsParser.currentLineIndex(in: [], at: 10) == nil)
    }

    @Test func musicKeyGuardOnlySwallowsUnclaimedPlayKeyDown() {
        #expect(MusicKeyGuard.shouldSwallow(keyCode: 16, isKeyDown: true, hasPlayer: false, musicRunning: false))
        #expect(!MusicKeyGuard.shouldSwallow(keyCode: 15, isKeyDown: true, hasPlayer: false, musicRunning: false))
        #expect(!MusicKeyGuard.shouldSwallow(keyCode: 17, isKeyDown: true, hasPlayer: false, musicRunning: false))
        #expect(!MusicKeyGuard.shouldSwallow(keyCode: 16, isKeyDown: false, hasPlayer: false, musicRunning: false))
        #expect(!MusicKeyGuard.shouldSwallow(keyCode: 16, isKeyDown: true, hasPlayer: true, musicRunning: false))
        #expect(!MusicKeyGuard.shouldSwallow(keyCode: 16, isKeyDown: true, hasPlayer: false, musicRunning: true))
    }
}
