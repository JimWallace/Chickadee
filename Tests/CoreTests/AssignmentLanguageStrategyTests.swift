import Testing

@testable import Core

@Suite struct AssignmentLanguageStrategyTests {
    @Test func inputsFileName() {
        #expect(AssignmentLanguage.python.inputsFileName == "_ck_inputs.py")
        #expect(AssignmentLanguage.r.inputsFileName == "_ck_inputs.R")
    }

    @Test func literalDispatch() {
        #expect(AssignmentLanguage.python.literal(.bool(true)) == "True")
        #expect(AssignmentLanguage.r.literal(.bool(true)) == "TRUE")
        #expect(AssignmentLanguage.python.literal(.null) == "None")
        #expect(AssignmentLanguage.r.literal(.null) == "NULL")
        #expect(AssignmentLanguage.r.literal(.array([.string("a"), .string("b")])) == "c(\"a\", \"b\")")
    }

    @Test func pythonInputsFileIsByteForByteHistorical() {
        // Must match the historical _ck_inputs.py writer exactly (keys sorted,
        // "key": value, per line WITH trailing comma, closing brace, trailing \n).
        let body = AssignmentLanguage.python.renderInputsFile(["b": "2", "a": "'x'"])
        let expected =
            "# Auto-generated per-student grading inputs (issue #461). Do not edit.\n"
            + "_ck = {\n"
            + "    \"a\": 'x',\n"
            + "    \"b\": 2,\n"
            + "}\n"
        #expect(body == expected)
    }

    @Test func rInputsFileSingle() {
        let body = AssignmentLanguage.r.renderInputsFile(["reads": "c(\"AC\", \"GT\")"])
        let expected =
            "# Auto-generated per-student grading inputs (issue #461). Do not edit.\n"
            + ".ck_inputs <- list(\n"
            + "    `reads` = c(\"AC\", \"GT\")\n"
            + ")\n"
        #expect(body == expected)
    }

    @Test func rInputsFileMultipleHasNoTrailingComma() {
        let body = AssignmentLanguage.r.renderInputsFile(["a": "1", "b": "2"])
        let expected =
            "# Auto-generated per-student grading inputs (issue #461). Do not edit.\n"
            + ".ck_inputs <- list(\n"
            + "    `a` = 1,\n"
            + "    `b` = 2\n"
            + ")\n"
        #expect(body == expected)
    }

    @Test func rInputsFileEmpty() {
        let body = AssignmentLanguage.r.renderInputsFile([:])
        let expected =
            "# Auto-generated per-student grading inputs (issue #461). Do not edit.\n"
            + ".ck_inputs <- list()\n"
        #expect(body == expected)
    }
}
