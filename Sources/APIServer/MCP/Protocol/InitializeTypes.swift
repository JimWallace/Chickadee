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
        test suites, and starter notebooks. It never exposes student data, grades, submissions, or \
        enrollment management.

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
        Family IDs and case keys come from get_suite.
        - Starter notebook — the .ipynb a student opens, stored as Jupyter JSON.
        - Validation — the server validates an assignment's suite against its solution; an assignment \
        cannot be opened (isOpen=true) until validation passes.

        Recommended workflow:
        1. Discover: list_courses, then list_assignments for a course.
        2. Inspect before editing: get_assignment, get_suite, get_notebook.
        3. Edit: update_assignment (metadata), update_suite (script metadata), update_pattern_family \
        (family defaults/cases), update_notebook (replace the starter notebook). To create a new \
        assignment, clone_assignment from a known-good one and then edit the copy.

        Important behaviors:
        - Any content edit (suite, pattern family, notebook) re-runs validation asynchronously; \
        re-read get_assignment to see validationStatus settle. Metadata-only edits via \
        update_assignment never trigger a regrade.
        - update_notebook replaces only the starter notebook; students keep their in-progress copies \
        and pick up the new notebook when their copy is next reset. Call get_notebook first and edit \
        the returned JSON.
        - clone_assignment lands closed, unvalidated, with no due date and no submissions, so nothing \
        is regraded; validate and open it with update_assignment when ready.
        - You author structure and metadata, not the underlying test logic: you cannot write raw \
        script bodies or a pattern case's args/expected values.
        - Resources: each accessible assignment's raw test.properties.json manifest is also exposed \
        as an MCP resource (resources/list, then resources/read on \
        chickadee://assignment/<publicID>/manifest). get_suite is the structured view; the resource \
        is the verbatim canonical JSON, useful to read the full authoring spec into context.
        """
}
