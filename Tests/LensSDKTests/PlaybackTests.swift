import XCTest

@testable import LensSDK

/// Every (state, fact) pair, written out by hand rather than derived from the
/// transition table, so a changed transition fails here and must be meant.
/// `-` is "no change"; `none` is a session before its first state. `f` is
/// final and handled before the table. The same matrix as web's
/// playback.test.ts.
final class PlaybackTests: XCTestCase {
    private static let matrix = """
                          none  s  p  k  r  a  w  e  d
          play             s    -  -  -  -  -  s  s  s
          playing          p    p  p  p  p  p  p  p  p
          pause            -    a  a  a  a  -  -  -  -
          waiting          -    -  r  -  -  -  -  -  -
          seeking          -    -  k  -  k  k  -  k  -
          seeked           -    -  -  p  -  -  -  -  -
          ended            e    e  e  e  e  e  e  e  e
          waitingForInput  w    w  w  w  w  w  w  -  w
        """

    private static let facts: [String: TransitionFact] = [
        "play": .play, "playing": .playing, "pause": .pause, "waiting": .waiting,
        "seeking": .seeking, "seeked": .seeked, "ended": .ended,
        "waitingForInput": .waitingForInput,
    ]

    private struct Row {
        let fact: TransitionFact
        let expected: [PlayerState?]
    }

    private static func parse() -> (columns: [PlayerState?], rows: [Row]) {
        let lines = matrix.split(separator: "\n").map {
            $0.split(separator: " ").map(String.init)
        }
        let columns = lines[0].map { $0 == "none" ? nil : PlayerState(rawValue: $0) }
        let rows = lines.dropFirst().map { cells in
            Row(
                fact: facts[cells[0]]!,
                expected: cells.dropFirst().map { $0 == "-" ? nil : PlayerState(rawValue: $0) })
        }
        return (columns, rows)
    }

    func testCoversEveryFactThatMovesTheState() {
        XCTAssertEqual(
            Set(Self.parse().rows.map { "\($0.fact)" }),
            Set(TransitionFact.allCases.map { "\($0)" }))
    }

    func testEachFactMovesEachStateAsCta5004BDescribes() {
        let (columns, rows) = Self.parse()
        for row in rows {
            XCTAssertEqual(
                columns.map { nextState($0, row.fact, paused: false) }, row.expected,
                "\(row.fact)")
        }
    }

    func testASeekLandsBackInPauseWhenThePlayerIsPaused() {
        XCTAssertEqual(nextState(.seeking, .seeked, paused: true), .paused)
        XCTAssertEqual(nextState(.seeking, .seeked, paused: false), .playing)
    }

    func testBeingPausedChangesNoOtherTransition() {
        let (columns, rows) = Self.parse()
        for row in rows where row.fact != .seeked {
            for state in columns {
                XCTAssertEqual(
                    nextState(state, row.fact, paused: true),
                    nextState(state, row.fact, paused: false))
            }
        }
    }
}
