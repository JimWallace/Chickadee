# Vapor 5 migration

Chickadee runs on Vapor 4. Vapor 5 is in beta (`5.0.0-beta.4`, October 2026).
This file records what Chickadee did on Vapor 4 to make the move small, and
what is left for the move itself. Update it when a step lands or when a new
beta changes an API listed here.

The Vapor team advises against the beta for production. Do not start the move
until Fluent, JWT and response compression support Vapor 5 and a migration guide
exists.

---

## What Vapor 5 changes

These facts come from the Vapor 5 source at `5.0.0-beta.4`.

- **Async only.** There is no `EventLoopFuture`, no event loop and no
  `application.threadPool`. `Middleware` and `SessionDriver` are async
  protocols. Every `LifecycleHandler` method is async.
- **The request is smaller.** `Request` has no `application`, `logger`,
  `storage` or `eventLoop`. The logger is the task-local `Logger.current`.
- **Bodies stream.** `req.content.decode` is async. `ContentContainer` has no
  `get(_:at:)`.
- **Swift HTTP Types.** Headers are `HTTPFields`, and the status is
  `HTTPResponse.Status`. Two status names change: `.unprocessableEntity`
  becomes `.unprocessableContent`, and `.payloadTooLarge` becomes
  `.contentTooLarge`.
- **Swift Configuration.** `Application(_:configuration:configReader:services:)`
  reads its settings through a `ConfigReader`.
- **A new `VaporTesting`.** It has its own top-level `withApp`.
- **macOS 26.2 or later.** Linux is not affected.

---

## Done on Vapor 4

Each step is safe on Vapor 4 and does not change behaviour.

| Step | Where | Result at the move |
|---|---|---|
| The session driver is async | `Bootstrap/UnchangedSessionSkippingDriver.swift` | Its methods already match the Vapor 5 `SessionDriver`. |
| Blocking work uses no event loop | `Utilities/BlockingWork.swift` | `runBlocking` calls `NIOThreadPool.singleton`, the pool Vapor 4 uses. No change. |
| The support-file client uses no event loop | `MCP/Tools/SupportFileURLFetcher.swift` | No change. |
| GitHub calls need no `Request` | `GitHub/GitHubCallScope.swift` | The background commit-status post uses `BackgroundGitHubCallScope`. The protocol is the seam for a request without `application`. Its database logs use the application logger, not the request logger. |
| Lifecycle hooks are async | `Services/PeriodicSweepMonitor.swift`, `Services/ServerHealthAlertService.swift` | Rename `didBootAsync` to `didBoot` and `shutdownAsync` to `shutdown`. The synchronous `boot()` does not run async hooks, so boot with `execute()` or `asyncBoot()`. |
| One request-body decode | `Helpers/Request+DecodeContent.swift` | Add `await` inside this one helper. Every call site already awaits it. |
| One client-body read and decode | `Helpers/ClientResponse+Body.swift` | Change this one file for the new client body. Every decode already awaits it. |
| Poll fragments take a `String` | `Routes/Web/PollFragmentResponse.swift` | No `ByteBuffer` in its API. |
| One test seam | `Tests/APITests/TestRequests.swift` | Re-implement its names on the Vapor 5 `TestClient` (see "The tests"). |
| Poll fragments in the tests | `PollFragmentResponseTests`, `PollFragmentCSRFTests` | They pass a `String`. |
| The macOS floor | `Package.swift` | It is `.macOS("26.2")`, the Vapor 5 minimum. No change. |
| A guard keeps it so | `scripts/check-vapor5-readiness.sh` | `format-lint` fails on new event-loop API, on `content.decode` outside the two helpers, and on a test that uses VaporTesting or builds a `Request` outside the seam. |

---

## Left for the move

### Waits for Vapor 5 and Fluent 5

- **`req.application` (about 330 uses), `req.logger` (about 130) and
  `req.storage` (12).** Wait for the stable `Request` API. `GitHubCallScope`
  shows one way to carry the application and the database without a request.
- **`req.db` (about 880 uses) and the Fluent models.** Wait for Fluent 5.
- **Headers and status codes** (about 150 uses of `HTTPHeaders`,
  `replaceOrAdd` and `first(name:)`). This change is mechanical.
- **`request.content.get(_:at:)`** in `Middleware/CSRFTokenRetrieval.swift`.
  Vapor 5 removes it.
- **Configuration.** All environment reads go through `AppConfig`
  (`Configuration/`), so the move to `ConfigReader` stays in that directory.
  It adds no environment variable.

### Uses of `ByteBuffer` that stay

Each one goes through a Vapor or AsyncHTTPClient API that Vapor 5 rewrites, so
a change now would be done again at the move.

- Streaming response writers: `MCP/Transport/MCPRoutes.swift`,
  `MCP/Transport/MCPTransport.swift`.
- Multipart and `File`: `Routes/Web/MultipartHelpers.swift`,
  `Helpers/SuiteConfigBuilding.swift`,
  `Routes/Web/DraftAssignmentRoutes+NewAssignment.swift`. Vapor 5 keeps
  `ByteBuffer` in multipart.
- The uploaded-bundle body: `Routes/Web/CourseBundleRoutes+Import.swift`.
- Vapor client requests: `LTI/LTIServiceClient.swift`.
- AsyncHTTPClient bodies and timeouts (`NIOCore`): `GitHub/GitHubRepoClient.swift`,
  `GitHub/GitHubTransport.swift`, `MCP/Tools/SupportFileURLFetcher.swift`,
  `Routes/Web/AuthRoutes.swift`. Vapor 5 still uses AsyncHTTPClient.

### The tests

The test target reaches VaporTesting through one file,
`Tests/APITests/TestRequests.swift`:

- `app.asyncTest` and `app.asyncSendRequest` send every request. Their
  closures are async, as in Vapor 5.
- `TestRequest` and `TestResponse` name the request and response types.
- `makeTestRequest(on:method:url:headers:)` builds the `Request` that code under
  test takes, which is the only place a test names an event loop.
- `asyncTest` boots with `asyncBoot()`, so the async lifecycle hooks run in
  tests as they do in production and in Vapor 5.

At the move, re-implement those names on the Vapor 5 `TestClient`. The guard
fails on a direct use under `Tests/` elsewhere.

Left for the move:

- Chickadee's own `withApp(_:_:)` and the Vapor 5 `withApp(configure:_:)` have
  different signatures, so they do not collide. Keep both names.
- Three Vapor `Client` stand-ins (`BrightSpaceVerbDispatchTests`,
  `GitHub/ScriptedGitHubClient`, `GitHub/GitHubTransportTests`) and two Fluent
  `Database` stand-ins (`CourseCloneCleanupTests`,
  `CourseBundleImportCleanupTests`) return futures. They implement the Vapor 4
  and Fluent 4 protocols, so they change with those protocols.
