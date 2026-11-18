// Tests/CoreTests/CSVFieldRangesQuoteTests.swift
//
// `DatasetMaterializer.fieldRanges(of:)`, which finds the raw span of each
// field so a transform can edit one cell in place. The coverage report showed
// that no test gave it a doubled quote (an escaped quote inside a quoted
// field). The ranges must agree with `splitCSVLine` on the field count, or a
// transform would edit the wrong cell.

import Testing

@testable import Core

@Suite struct CSVFieldRangesQuoteTests {

    private static func fields(_ line: String) -> [String] {
        let sub = Substring(line)
        return DatasetMaterializer.fieldRanges(of: sub).map { String(sub[$0]) }
    }

    @Test func anEscapedQuoteStaysInsideItsField() {
        let line = #"7,"says ""hi, there""",ok"#

        #expect(Self.fields(line) == ["7", #""says ""hi, there""""#, "ok"])
    }

    @Test func anEscapedQuoteAtTheEndOfAFieldDoesNotCloseIt() {
        let line = #""a""",b"#

        #expect(Self.fields(line) == [#""a""""#, "b"])
    }

    @Test(arguments: [
        #"7,"says ""hi, there""",ok"#,
        #""a""",b"#,
        #"x,"""",y"#,
        "plain,,cells",
    ])
    func theRangesAgreeWithTheSplitter(line: String) {
        #expect(
            DatasetMaterializer.fieldRanges(of: Substring(line)).count
                == DatasetMaterializer.splitCSVLine(Substring(line)).count)
    }
}
