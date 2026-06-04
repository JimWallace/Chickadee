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

/// Capabilities this server advertises at initialization.  `tools` and
/// `resources` are advertised; `prompts` is not.  `listChanged` is false on
/// both (no server-initiated list-change notifications), and resources are not
/// subscribable.
struct MCPServerCapabilities: Encodable, Sendable {
    let tools: ListChanged
    let resources: Resources

    struct ListChanged: Encodable, Sendable {
        let listChanged: Bool
    }

    struct Resources: Encodable, Sendable {
        let subscribe: Bool
        let listChanged: Bool
    }

    /// The capability set advertised by v1: tools + resources, neither pushing
    /// list-change notifications, resources not subscribable.
    static let v1 = MCPServerCapabilities(
        tools: ListChanged(listChanged: false),
        resources: Resources(subscribe: false, listChanged: false))
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

        Access scope: you may only act on courses the authenticated account is enrolled in (an admin \
        account may act on every course); students cannot use this interface. Read tools require the \
        content:read scope; write tools require content:write.

        Key concepts:
        - Course — identified by a short code (e.g. "CS136").
        - Assignment — identified by a 6-character public ID; has a title, an optional due date \
        (ISO 8601), and an open/closed state.
        - Test suite — the ordered checks that grade an assignment. Each item is a hand-written \
        script, a generated pattern family, or a notebook check, and carries a tier \
        (public/release/secret/student), points, an optional section, and prerequisites (dependsOn). \
        get_suite returns the full definition of every item, not just its metadata: each \
        hand-written script's raw body, each pattern family's complete spec (function, paramNames, \
        defaults, and every case's args/expected), and each notebook check's spec — so you can read \
        exactly what a test checks (e.g. to explain why a submission lost points).
        - Starter notebook — the .ipynb a student opens, stored as Jupyter JSON.
        - Solution — the instructor's reference answer key (.ipynb), validated against the suite. It \
        is instructor-authored content, never a student submission. Read with get_solution, replace \
        with update_solution (which stores it as the validation submission and re-runs validation).
        - Global inputs (personalization) — assignment-scoped names that vary the assignment per \
        student: literal `variables` (a name + JSON value) and `expressions` (a name + Python source \
        evaluated against the student's `seed`). They inline into generated/raw tests and substitute \
        into the starter notebook's `{{name}}` placeholders. Read with get_global_inputs, replace \
        with update_global_inputs. Sections can also carry their own scoped variables/expressions \
        (same shape); get_suite returns them per section and update_section_variables replaces them.
        - Visibility — an assignment is closed, preview, or open (set via update_assignment `visibility`, \
        or the legacy `isOpen` boolean for open/closed). `preview` is a staff-only beta state: only \
        course staff can see it and they may test-submit to it, while students still can't see it. The \
        lifecycle is one-way (closed → preview → open); moving an already-open assignment to preview is \
        refused. Both preview and open require the suite's runner validation to have passed.

        Recommended workflow:
        1. Discover: list_courses, then list_assignments for a course. get_server_info reports the \
        deployed version and whether writes are honored — call it to confirm a feature/deploy is live \
        (a tool call reflects the running process even if your tool list is cached).
        2. Inspect before editing: get_assignment, get_suite, get_notebook, get_solution, \
        get_global_inputs. Use \
        preview_personalization to see the name→value map and starter-notebook placeholder audit a \
        student (or a given seed) would get.
        3. Edit: update_assignment (metadata), update_suite (script metadata), update_pattern_family \
        (family defaults/cases), update_global_inputs (personalization variables/expressions), \
        update_section_variables (a section's scoped variables/expressions), update_notebook (replace \
        the starter notebook), update_solution (replace the reference solution and re-validate), \
        author_script (create/replace a hand-written test or support file). To create a new \
        assignment, either clone_assignment from a known-good one and then edit the copy (the safest \
        path) or create_assignment to start a fresh notebook-based assignment from a starter .ipynb.

        Important behaviors:
        - Any content edit (suite, pattern family, notebook, solution) re-runs validation \
        asynchronously AND closes the assignment if it was open (each write tool's response reports \
        this as `assignmentClosed`), so students can't submit against a not-yet-revalidated suite. \
        Call validate_assignment to wait for the terminal status (passed/failed/no-runner, with live \
        queued -> running -> done progress over an SSE connection), then re-open with \
        update_assignment(visibility:"open") — or visibility:"preview" to beta-test as staff first — \
        once it passes (opening and previewing are refused until it does). \
        Metadata-only edits via update_assignment never trigger a regrade or a close.
        - update_notebook replaces only the starter notebook; students keep their in-progress copies \
        and pick up the new notebook when their copy is next reset. Call get_notebook first and edit \
        the returned JSON.
        - clone_assignment lands closed, unvalidated, with no due date and no submissions, so nothing \
        is regraded; validate and open it with update_assignment when ready.
        - get_suite returns the full source of truth for reading: hand-written script bodies, \
        complete pattern-family specs, and notebook-check specs. For authoring, update_pattern_family \
        edits a generated case's args/expected (validated on save), and author_script writes a single \
        hand-written file into the test setup. A test tier (public/release/secret/student) creates or \
        replaces the script AND its suite entry — set points/displayName/dependsOn/sectionID alongside \
        the body; the runner reads the per-student seed from the CHICKADEE_ASSIGNMENT_SEED env var, so \
        a secret test can re-derive a personalized expected answer. The "support" tier writes a \
        non-graded helper file (e.g. a data generator) that tests and personalization expressions can \
        import by stem. Generated pattern-family / notebook-check scripts are not editable via \
        author_script — edit the family/check instead.
        - Resources: each accessible assignment's raw test.properties.json manifest is also exposed \
        as an MCP resource (resources/list, then resources/read on \
        chickadee://assignment/<publicID>/manifest). get_suite is the structured view; the resource \
        is the verbatim canonical JSON, useful to read the full authoring spec into context.
        """
}
