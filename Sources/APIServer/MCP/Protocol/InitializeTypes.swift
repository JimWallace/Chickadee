// APIServer/MCP/Protocol/InitializeTypes.swift
//
// Result types for the MCP `initialize` handshake.  Capabilities advertise
// what v1 implements — tools and resources, without list-change notifications,
// since there is no server-initiated streaming yet.  The result also carries a
// human-readable `instructions` string so a connecting agent learns the domain
// model, the read-before-write workflow, and the validation/safety rules up
// front rather than reverse-engineering them from the tool list alone.
// https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle

/// The result returned from an `initialize` request.
struct MCPInitializeResult: Encodable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo
    /// Free-form guidance the client can feed to the model to improve its use
    /// of this server (omitted from the wire when nil).
    let instructions: String?
}

/// The client-supplied params of an `initialize` request.  Only the fields the
/// server reacts to are modelled — the requested protocol revision (echoed
/// back when supported) and the client's self-identification (logged for
/// operational visibility, never trusted for anything).  Unknown fields and
/// malformed params are ignored rather than rejected: a lenient initialize
/// maximises client compatibility, and the server-chosen version is the
/// correct answer to an unreadable request anyway.
struct MCPInitializeParams: Decodable, Sendable {
    let protocolVersion: String?
    let clientInfo: ClientInfo?

    struct ClientInfo: Decodable, Sendable {
        let name: String?
        let version: String?
    }
}

/// Capabilities this server advertises at initialization.  `tools` is always
/// advertised; `resources` is optional and omitted from the wire when nil (a
/// surface that has no resources doesn't advertise the capability).  `prompts`
/// is not advertised.  `listChanged` is false (no server-initiated list-change
/// notifications), and resources are not subscribable.
struct MCPServerCapabilities: Encodable, Sendable {
    let tools: ListChanged
    let resources: Resources?

    struct ListChanged: Encodable, Sendable {
        let listChanged: Bool
    }

    struct Resources: Encodable, Sendable {
        let subscribe: Bool
        let listChanged: Bool
    }

    enum CodingKeys: String, CodingKey {
        case tools, resources
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tools, forKey: .tools)
        // Omit `resources` entirely when nil so a tools-only surface doesn't
        // advertise a capability it doesn't implement.
        try container.encodeIfPresent(resources, forKey: .resources)
    }

    /// The capability set advertised by v1 (the content surface): tools +
    /// resources, neither pushing list-change notifications, resources not
    /// subscribable.
    static let v1 = MCPServerCapabilities(
        tools: ListChanged(listChanged: false),
        resources: Resources(subscribe: false, listChanged: false))

    /// Tools-only capability set (the admin diagnostic surface): no resources.
    static let toolsOnly = MCPServerCapabilities(
        tools: ListChanged(listChanged: false),
        resources: nil)
}

/// Identifies this server to the client in the `initialize` result.  `name` is
/// the stable programmatic identifier; `title` is an optional human-friendly
/// display name (omitted from the wire when nil).
struct MCPServerInfo: Encodable, Sendable {
    let name: String
    let title: String?
    let version: String

    init(name: String, version: String, title: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
    }
}

/// Server-level guidance surfaced in the `initialize` result's `instructions`
/// field.  This is the one place an agent is taught the whole picture, so it
/// covers the domain vocabulary, the recommended workflow, and the
/// validation/scope/safety rules that aren't obvious from any single tool.
enum MCPServerInstructions {
    static let text = """
        Chickadee is a course-content authoring and autograding platform. This server lets an \
        authorized agent author assignment content on an instructor's behalf: assignment metadata, \
        test suites, starter notebooks, and reference solutions. It never exposes student data, \
        grades, student submissions, or enrollment management.

        Access scope: you may only act on courses the authenticated account is enrolled in — for \
        every role, admins included. Enrolling the account in a course widens this agent's reach; \
        unenrolling revokes it immediately. Students cannot use this interface. Read tools require \
        the content:read scope; write tools require content:write.

        Key concepts:
        - Course — identified by a short code (e.g. "CS136").
        - Assignment — identified by a 6-character public ID; has a title, an optional due date \
        (ISO 8601), and an open/closed state.
        - Course section — a named group of assignments within a course (e.g. "Labs", "Exams"); an \
        assignment belongs to at most one. Distinct from a test-suite section (which groups tests \
        inside one assignment). List with list_course_sections, create with create_course_section, \
        rename or change the default grading mode with rename_course_section, reorder with \
        reorder_course_sections, delete with delete_course_section (assignments in it are ungrouped, \
        not deleted), and assign an assignment with set_assignment_course_section (which adopts the section's \
        default grading mode). get_assignment reports an assignment's current course section. Order \
        the assignments themselves within the list with reorder_assignments (a course-global order, \
        lower first; the dashboard still groups the ordered assignments by their section for display).
        - Course content item — ungraded reference material shown to students inside a course section \
        alongside assignments: a link, notebook, document, slides, outline, or heading, each with a \
        title and one or more labelled links ({label, url}; http(s) or site-relative only). It owns no \
        test setup, so creating or editing one never validates, re-grades, or closes anything. List with \
        list_content_items, create with create_content_item (optionally into a course section via \
        courseSectionID; isPublished:false hides it from students as a draft), edit or move with \
        update_content_item, remove with delete_content_item, and order a section's content lane with \
        reorder_content_items. Distinct from assignments (list_assignments) and test-suite items \
        (get_suite).
        - Test suite — the ordered checks that grade an assignment. Each item is a hand-written \
        script, a generated pattern family, or a notebook check, and carries a tier \
        (public/release/secret/student), points, an optional section, prerequisites (dependsOn), and \
        an optional "💡 Hint" shown to the student only when that test fails. \
        get_suite returns the full definition of every item, not just its metadata: each \
        hand-written script's raw body, each pattern family's complete spec (function, paramNames, \
        defaults, and every case's args/expected/hint), and each notebook check's spec — so you can \
        read exactly what a test checks (e.g. to explain why a submission lost points).
        - Starter notebook — the .ipynb a student opens, stored as Jupyter JSON.
        - Solution — the instructor's reference answer key (.ipynb), validated against the suite. It \
        is instructor-authored content, never a student submission. Read with get_solution, replace \
        with update_solution (which stores it as the validation submission and re-runs validation).
        - Support files — non-graded helper/data files bundled in the setup zip (e.g. a CSV a check \
        loads, a helper module tests import). List or read them with get_support_files (byte-capped \
        reads, so big datasets return a useful head); write one with author_script(tier:"support") — \
        passing the body inline as content, or, for a data file too large to inline faithfully (e.g. a \
        big CSV), passing sourceUrl (an https URL the server fetches under an SSRF guard: https only, \
        no private/loopback/metadata hosts, no redirects, 8 MB cap, UTF-8 body). \
        Confirm a data file is bundled before authoring checks that load it. A support data file can \
        also be marked as a per-student DATASET with set_dataset: each student then receives a \
        deterministic per-seed sample of its rows under the same filename (the uploaded file becomes \
        the hidden server-side pool), so every student explores their own data; get_support_files \
        reports the mark (isDataset / datasetSampleSize) and remove:true clears it.
        - Global inputs (personalization) — assignment-scoped names that vary the assignment per \
        student: literal `variables` (a name + JSON value) and `expressions` (a name + Python source \
        evaluated against the student's `seed`). They inline into generated/raw tests and substitute \
        into the starter notebook's `{{name}}` placeholders. Read with get_global_inputs, replace \
        with update_global_inputs. Sections can also carry their own scoped variables/expressions \
        (same shape); get_suite returns them per section and update_section_variables replaces them. \
        Expression scope: besides `seed` and the declared variables, the solution's code cells are \
        auto-extracted into a `solution` module and every uploaded `.py` support file is auto-imported \
        under its module name. When an expression needs a transform the solution already implements — \
        e.g. encoding a value the student will later invert — CALL it \
        (`solution.composite(fortune, 1 + seed % 25, 2 + seed % 5)`) rather than re-implementing it \
        inline. An inline re-implementation can drift from the graded code on edge cases and silently \
        mis-grade some seeds; keep one source of truth and reuse it. The `solution` auto-import is \
        best-effort — skipped when the solution uses `{{ }}` placeholders (which break its import); for \
        those, share the function via an uploaded `.py` support module that both the solution and the \
        expression import.
        - Achievements — instructor-authored awards shown to students, separate from grading. Each is a \
        scope (an `individual` per-student badge, a `classWide` collaborative goal, or a single-holder \
        competitive `record`), a list of conditions over a submission's signals (grade, attempts, \
        executionTimeMs, gradeJumpPercent, testPass) combined with `match` (all/any), and the scope's \
        reward (classPercent + points for a goal, recordDimension for a record). Read them with \
        get_achievements, replace the whole list with update_achievements. They are server-evaluated \
        and DISPLAY-ONLY — they never change what the suite grades, so editing them does not re-validate, \
        re-grade, or close the assignment (unlike every other content edit).
        - Visibility — an assignment is closed, preview, or open (set via update_assignment `visibility`, \
        or the legacy `isOpen` boolean for open/closed). `preview` is a staff-only state: course staff \
        see and use it exactly like an open assignment (its bundled solution and tests, normal grading), \
        while students see it as closed. Switching to preview is a pure visibility change with no side \
        effects — it neither re-validates nor closes anything. Only opening to students requires the \
        suite's runner validation to have passed.

        Recommended workflow:
        1. Discover: list_courses, then list_assignments for a course. get_server_info reports the \
        deployed version and whether writes are honored — call it to confirm a feature/deploy is live \
        (a tool call reflects the running process even if your tool list is cached).
        2. Inspect before editing: get_assignment, get_suite, get_notebook, get_solution, \
        get_support_files, get_global_inputs, get_achievements. Use \
        preview_personalization to see the name→value map and starter-notebook placeholder audit a \
        student (or a given seed) would get.
        3. Edit: update_assignment (metadata), set_grading_mode (worker vs browser grading), \
        set_time_limit (the assignment's default per-test timeout in seconds; a per-test \
        timeLimitSeconds override, 1–600s, can be set on a hand-written script via author_script / \
        update_suite, on a pattern family via create_pattern_family / update_pattern_family \
        (family-wide defaultTimeLimitSeconds and/or per-case timeLimitSeconds), and on a notebook \
        check via author_notebook_check — 0 clears an override), \
        update_suite (script metadata). To add or change a GRADED test, prefer Chickadee's native \
        check types — update_pattern_family (edit a family's defaults/cases) / create_pattern_family \
        (add a new family) and author_notebook_check (create/replace a notebook check) — over a \
        hand-written script (see "Prefer native check types" below). Personalization and grouping: \
        update_global_inputs (personalization variables/expressions), update_achievements (the \
        display-only awards shown to students), update_section_variables (a \
        section's scoped variables/expressions), create_suite_section / rename_suite_section / \
        delete_suite_section (manage the named display groups), move_suite_item (place a script, \
        family, or check into a section, or ungroup it), delete_suite_item (remove a script, family, \
        or check). Notebook/solution: update_notebook (replace the starter notebook), update_solution \
        (replace the reference solution and re-validate). Escape hatch: author_script (create/replace \
        a hand-written test — only when no native kind fits — or a non-graded support/helper file). \
        To create a new assignment, either clone_assignment from a known-good one and then edit the \
        copy (the safest path) or create_assignment to start a fresh notebook-based assignment from a \
        starter .ipynb.

        Important behaviors:
        - Prefer native check types over hand-written scripts. To author a graded test, first check \
        whether a pattern family or a notebook check expresses the assertion, and use that instead of \
        a raw script. Pattern-family kinds (create_pattern_family / update_pattern_family): \
        boundary_equality and approximate_equality (a function's return equals / is within tolerance \
        of an expected value), variable_equality (a module-level variable equals a value), \
        return_type_check, exception_expected, performance_threshold, stdout_equality, and \
        unordered_equality (a function's return equals an expected collection ignoring order). \
        A function-calling family auto-generates a 0-point `<function> is defined` existence guard \
        that its cases depend on, so a missing/non-callable function fails once and the cases skip — \
        you rarely need a standalone function_exists check alongside a family. \
        Notebook-check kinds (author_notebook_check): data_frame_shape, data_frame_columns, \
        data_frame_equality, series_equality, numeric_array_close, figure_count, cell_contains, \
        function_exists, variable_exists, and ast_structure. Native checks are validated structurally \
        when you save (arg count, the expected's shape for the kind, $ref resolution), they \
        personalize per student ($name / expectedVarRef), and get_suite returns their full spec so a \
        later reader can see exactly what they assert. author_script is the escape hatch: it writes \
        the file verbatim, so the only safety net is the asynchronous validation run and the body is \
        opaque to anything reading the suite back. Use a graded tier of author_script only when the \
        assertion genuinely cannot be expressed as any pattern kind or notebook check — and when you \
        do, say why no native construct fit. (Writing a non-graded support/helper file with the \
        support tier is a normal, primary use of author_script, not a fallback.)
        - Any content edit (suite, pattern family, check, script, notebook, solution) re-runs \
        validation asynchronously AND closes the assignment if it was open (each write tool's response \
        reports this as `assignmentClosed`), so students can't submit against a not-yet-revalidated \
        suite. A suite/family/check/script edit also automatically re-queues every existing student \
        submission to be re-graded against the edited suite — the automatic equivalent of the \
        instructor "Retest all" button — so prior results reflect the new tests; this fan-out is gated \
        on a real change to the test manifest. (move_suite_item only re-orders/re-tags items and so \
        does not re-grade; update_notebook and update_solution don't change the graded suite either.) \
        Call validate_assignment to wait for the terminal status (passed/failed/no-runner, with live \
        queued -> running -> done progress over an SSE connection), then re-open with \
        update_assignment(visibility:"open") — or visibility:"preview" to beta-test as staff first — \
        once it passes (opening and previewing are refused until it does). \
        When validation fails, call get_validation_result for the per-test outcomes of your reference \
        solution's latest run — each check's status plus shortResult/longResult, across all tiers — so \
        you can see which check failed and why before fixing the suite or solution. It is \
        validation-only: it resolves the instructor's own reference-solution run and never exposes a \
        student submission, identity, or grade. \
        Metadata-only edits (update_assignment, set_grading_mode, set_time_limit, set_dataset, \
        update_achievements, the section-organization tools) never trigger a regrade or a close. \
        update_global_inputs and update_section_variables re-inline the shared inputs into the \
        affected scripts in place and likewise neither close nor regrade (matching the web Global \
        Inputs panel); re-run validate_assignment yourself after changing inputs that graded \
        scripts consume.
        - update_notebook replaces only the starter notebook; students keep their in-progress copies \
        and pick up the new notebook when their copy is next reset. Call get_notebook first and edit \
        the returned JSON.
        - clone_assignment lands closed, unvalidated, with no due date and no submissions, so nothing \
        is regraded; validate and open it with update_assignment when ready.
        - get_suite returns the full source of truth for reading: hand-written script bodies, \
        complete pattern-family specs, and notebook-check specs. For authoring, update_pattern_family \
        edits a generated case's args/expected and its hint — per-case `hint` or the family-wide \
        `defaultHint` (create_pattern_family takes the same), validated on save — and can also append \
        new cases (`addCases`) or replace the family's prerequisites (`dependsOn`) in place, so you \
        rarely need to recreate a family to grow its coverage or drop a dependency. author_script \
        writes a single \
        hand-written file into the test setup. A test tier (public/release/secret/student) creates or \
        replaces the script AND its suite entry — set points/displayName/dependsOn/sectionID alongside \
        the body; the runner reads the per-student seed from the CHICKADEE_ASSIGNMENT_SEED env var, so \
        a secret test can re-derive a personalized expected answer. The "support" tier writes a \
        non-graded helper file (e.g. a data generator) that tests and personalization expressions can \
        import by stem. Generated pattern-family / notebook-check scripts are not editable via \
        author_script — edit the family/check instead.
        - Per-student answers (notebooks). A student's answer can be a module-level VARIABLE \
        (e.g. `answer = ...`) or a FUNCTION. Watch the notebook extractor's import rule: a code cell's \
        top-level statement runs at grading-import time ONLY if it is a def/class/import or an \
        assignment whose right-hand side has NO function call — anything else (e.g. \
        `x = int(os.environ["CHICKADEE_ASSIGNMENT_SEED"], 16)`) is quarantined into \
        `if __name__ == "__main__":` and does NOT run at import, so the name is undefined to the \
        grader. Consequences: (1) a per-student answer that must be COMPUTED at module level can't be \
        — have the student write the discovered value as a literal, or use a function (function bodies \
        run at call time and may read CHICKADEE_ASSIGNMENT_SEED). (2) The reference solution must \
        produce the same per-student value, and a seed-agnostic solution can't compute it as a plain \
        module-level variable. Two supported ways: write the answer cell with a `{{name}}` placeholder \
        (declare `name` as a global-inputs expression, e.g. `1 + seed % 25`) — the SOLUTION notebook is \
        substituted per validation-seed just like the starter, so `shift = {{shift}}` becomes a literal \
        that survives import — or make the solution answer a function that reads \
        CHICKADEE_ASSIGNMENT_SEED at call time. Use preview_personalization to confirm what a \
        placeholder resolves to. Full recipe: read the \
        chickadee://docs/personalization-solution-notebooks resource. \
        - Resources: each accessible assignment's raw test.properties.json manifest is also exposed \
        as an MCP resource (resources/list, then resources/read on \
        chickadee://assignment/<publicID>/manifest). get_suite is the structured view; the resource \
        is the verbatim canonical JSON, useful to read the full authoring spec into context. \
        Authoring guides are exposed the same way under chickadee://docs/* — e.g. the per-student \
        solution-notebook recipe above.
        """
}
