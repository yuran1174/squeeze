import XCTest
@testable import SqueezeCore

final class VDFTests: XCTestCase {
    func testParsesNestedObjects() throws {
        let vdf = try VDFParser.parse("""
        "AppState"
        {
            "appid"   "570"
            "name"    "Dota 2"
            "nested"
            {
                "k" "v"
            }
        }
        """)
        XCTAssertEqual(vdf["AppState"]?["appid"]?.string, "570")
        XCTAssertEqual(vdf["AppState"]?["name"]?.string, "Dota 2")
        XCTAssertEqual(vdf["AppState"]?["nested"]?["k"]?.string, "v")
    }

    func testKeyLookupIsCaseInsensitive() throws {
        let vdf = try VDFParser.parse(#""AppState" { "stateflags" "4" }"#)
        XCTAssertEqual(vdf["appstate"]?["StateFlags"]?.string, "4")
    }

    func testEscapesAndComments() throws {
        let vdf = try VDFParser.parse("""
        // comment line
        "a" "x\\\\y\\"z"   // trailing comment
        "b" "line1\\nline2"
        """)
        XCTAssertEqual(vdf["a"]?.string, #"x\y"z"#)
        XCTAssertEqual(vdf["b"]?.string, "line1\nline2")
    }

    func testUnquotedTokens() throws {
        let vdf = try VDFParser.parse("key value\nobj { inner 1 }")
        XCTAssertEqual(vdf["key"]?.string, "value")
        XCTAssertEqual(vdf["obj"]?["inner"]?.string, "1")
    }

    func testUnbalancedBracesThrow() {
        XCTAssertThrowsError(try VDFParser.parse(#""a" { "b" "c""#))
        XCTAssertThrowsError(try VDFParser.parse(#""a" "b" }"#))
        XCTAssertThrowsError(try VDFParser.parse(#""a""#))
    }

    func testEmptyInputIsEmptyObject() throws {
        XCTAssertEqual(try VDFParser.parse("").entries.count, 0)
    }

    func testMissingKeyIsNil() throws {
        let vdf = try VDFParser.parse(#""a" "b""#)
        XCTAssertNil(vdf["zzz"])
        XCTAssertNil(vdf["a"]?["b"]) // a string has no children
    }
}
