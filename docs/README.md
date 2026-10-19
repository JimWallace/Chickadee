# Chickadee documentation index

This file lists every document in `docs/`. Each document holds its own rules
and evidence. The rules for the whole repository are in the root `CLAUDE.md`.
The rules for one area are in the `CLAUDE.md` of that area (the root
`CLAUDE.md`, "Where the Area Rules Live").

When you add a document to `docs/`, add one line for it here. The `docs-audit`
agent reports a document that has no line, and a line for a document that does
not exist.

## Architecture and grading

- [architecture.md](architecture.md) — system architecture: targets, grading pipeline, auth, sandboxing, MCP, deployment
- [grading-integrity.md](grading-integrity.md) — what a submission can do to its own grade today, the decisions, and the four-phase plan (#2223)
- [failure-detail.md](failure-detail.md) — how much of a failing test a student sees: `full`, `actualOnly` and `verdictOnly`
- [manifest-format-v2.md](manifest-format-v2.md) — proposed: the manifest (`TestProperties`) review, the v2 envelope and its phased rollout
- [runner-capability-profiles.md](runner-capability-profiles.md) — runner capability matching, the language gate, `minimumRunnerVersion`
- [feature-interactions.md](feature-interactions.md) — the shared objects that several features read or write, and the rule for each; the `interaction-review` agent's map
- [fitness-functions.md](fitness-functions.md) — the inventory of automated checks that hold the architecture

## Browser grading and the wasm runner

- [runner-wasm-serving.md](runner-wasm-serving.md) — how the Embedded-Swift wasm runner is optimized, cached and kept small
- [runner-wasm-swift-6-4-review.md](runner-wasm-swift-6-4-review.md) — what the Swift 6.4 move changed for the browser wasm, measured
- [swift-wasm-review-checklist.md](swift-wasm-review-checklist.md) — the review checklist for a Swift PR that targets WebAssembly

## Languages

- [language-declaration.md](language-declaration.md) — language is declared, never inferred, and the per-site `?? .python` table
- [authoring-parity.md](authoring-parity.md) — what a non-Python author can and cannot do, and which gaps are correct refusals
- [adding-a-xeus-kernel.md](adding-a-xeus-kernel.md) — the runbook for a new language: both halves, the compiler-invisible list, the parity checklist
- [r-support.md](r-support.md) — first-class R: runtime, personalization, renderers
- [cpp-support.md](cpp-support.md) — first-class C++: upload-only, the `.sh` wrapper, single-TU inclusion, the literal refusals
- [cpp-assignment-language-decision.md](cpp-assignment-language-decision.md) — the C++ memo, superseded in part; it still governs why C++ has no browser kernel
- [java-support.md](java-support.md) — first-class Java: why upload-only, the `.sh` wrapper, the three measured traps
- [multi-language-audit.md](multi-language-audit.md) — the Lua-to-Racket audit, with a "Status at merge" section
- [program-io.md](program-io.md) — the `programIO` pattern kind: stdin in, stdout graded, per language

## The notebook editor and JupyterLite

- [jupyterlite.md](jupyterlite.md) — the vendored editor and kernels: environments, import checks, re-vendoring, patches, stdin transports
- [kernel-boot-cost.md](kernel-boot-cost.md) — what a kernel boot costs, and on-demand package loading
- [notebook-editor-extension.md](notebook-editor-extension.md) — the Chickadee JupyterLite extension: theme, hidden chrome, bridge commands, page events, build and vendor
- [notebook-editor-kernel-boot.md](notebook-editor-kernel-boot.md) — the "Kernel Unknown" boot failure, its mitigation and the plan for the root-cause fix
- [notebook-editor-smoke-test.md](notebook-editor-smoke-test.md) — the pre-merge browser smoke test for the editor
- [notebook-editor-help.md](notebook-editor-help.md) — student help: what each editor notice means and what to do
- [notebook-guide.md](notebook-guide.md) — tests anchored to notebook cells by name, and the student guide the editor reads

## Authoring and personalization

- [authoring-editors.md](authoring-editors.md) — the suite editor, the notebook write-back, the language seed and server-side auto-compute
- [auto-compute.md](auto-compute.md) — auto-compute in the pattern-family editor
- [mcp-authoring-roadmap.md](mcp-authoring-roadmap.md) — the MCP authoring roadmap, largely delivered, and its tool index (`MCPRoadmapDocSyncTests` reads it)
- [assignment-versioning.md](assignment-versioning.md) — content version history: capture, read, restore
- [inputs.md](inputs.md) — global and section inputs: literals, `=` expressions, `$name` references
- [personalization-phase1.md](personalization-phase1.md) — the per-student seed contract (`CHICKADEE_ASSIGNMENT_SEED`)
- [personalization-pattern-families.md](personalization-pattern-families.md) — per-student values in pattern families
- [personalization-eval-runtime.md](personalization-eval-runtime.md) — where, and in which language, personalization expressions run
- [personalization-solution-notebooks.md](personalization-solution-notebooks.md) — per-student answers in notebooks and their reference solutions
- [personalization-drift-prevention-plan.md](personalization-drift-prevention-plan.md) — the plan that prevents drift between personalization and the solution
- [datasets.md](datasets.md) — per-student datasets (#1083)
- [datasets-course-library.md](datasets-course-library.md) — the per-course dataset library: versions and dictionary, attachments, the course cohort seed, the student Data page, the MCP tools, clone and bundle, `formatNoise`, the ranked-activity refusal and the dealt partition; opens with a Status table
- [examples/r-lab9-trial/](examples/r-lab9-trial/) — a worked R lab: starter, solution, data and test scripts for each tier

## Courses, roles and students

- [multi-course-roles.md](multi-course-roles.md) — per-course roles (#417): enrollment-row `CourseRole`, gates, staff invites
- [course-terms.md](course-terms.md) — course year and term, the two course-code resolvers, cloning for a new term
- [slip-days.md](slip-days.md) — student-managed slip days (#1228)
- [solution-visibility.md](solution-visibility.md) — the post-deadline solution reveal and its slip-day ceiling
- [unlockable-labs.md](unlockable-labs.md) — assignment prerequisites and sticky per-student unlocks
- [lti-1-3.md](lti-1-3.md) — LTI 1.3 tool support, and why a launch opens a new window
- [github-submissions.md](github-submissions.md) — submitting from GitHub and course repositories, with the "What reaches GitHub" data table
- [brightspace-setup.md](brightspace-setup.md) — BrightSpace grade-sync operator runbook

## Class activities

- [collaborative-class-assignments.md](collaborative-class-assignments.md) — shipped: contribution assignments and class goals
- [class-activities.md](class-activities.md) — shipped: leaderboards, bots, round robins, hills and brackets (#1508)
- [class-composite.md](class-composite.md) — shipped: each student renders one slot of a shared image, composed live on the projector
- [lab-groups.md](lab-groups.md) — shipped: lab groups and in-lab sessions: a session per (activity, group), a join code for the room, every class activity run once per group

## Achievements and avatars

- [achievements-unification.md](achievements-unification.md) — one achievements model, endpoint and editor; phases A to C shipped, phase D not finished
- [achievement-rewards.md](achievement-rewards.md) — proposed: achievements at the assignment, course and site levels, one award ledger, and a wardrobe item as a reward
- [result-celebration.md](result-celebration.md) — the result-page celebration: the 100% moment, the bird, and the Earned toast
- [student-avatars.md](student-avatars.md) — generated avatars and the per-course pseudonymous handle
- [avatar-species.md](avatar-species.md) — eleven avatar species on one shared skeleton, the colourway decides the species, the trait weights, the prototype findings; opens with a Status table
- [student-wardrobe.md](student-wardrobe.md) — cosmetic choices for the avatar, kept apart from earned status

## MCP and AI

- [admin-mcp.md](admin-mcp.md) — the read-only admin diagnostics MCP surface
- [ai-assisted-feedback.md](ai-assisted-feedback.md) — an instructor's own AI agent drafts feedback on written reasoning through MCP, behind two opt-in gates and staff review
- [mcp-client-allowlist-brief.md](mcp-client-allowlist-brief.md) — the implementation brief for the MCP client allowlist
- [compliance/](compliance/) — the UW approval package: student-data audits, tool and data-flow inventories

## UI

- [ui-design.md](ui-design.md) — the design system: tokens, component vocabulary, page archetypes, the guards and the usability heuristics
- [elementary-spike.md](elementary-spike.md) — the finished Leaf-to-Elementary migration: where the views live, the traps, the guards, the known remainder

## Operations, CI and releases

- [release-process.md](release-process.md) — versions at merge time, `changelog.d/` fragments, and cutting a minor release
- [zero-downtime-deploy.md](zero-downtime-deploy.md) — blue-green deploys, the `chickadee-deployer` daemon, read-only deploy oversight
- [operational-diagnostics.md](operational-diagnostics.md) — observability tables, log events, metrics endpoint, ops runbook
- [load-testing.md](load-testing.md) — `chickadee-loadtest`: simulated deadline traffic on the runner poll and the status poll
- [ci-flakiness.md](ci-flakiness.md) — CI flake families; start here before you chase a red check on an unrelated PR
- [swift-toolchain-upgrades.md](swift-toolchain-upgrades.md) — the semi-annual Swift upgrade: where the pins live, its traps, the verification gauntlet
- [vapor-5-migration.md](vapor-5-migration.md) — what Vapor 5 changes, the Vapor 4 preparation already done, and what is left for the move
- [testing-conventions.md](testing-conventions.md) — the test rules in full, with the reason for each
- [mutation-testing-pilot.md](mutation-testing-pilot.md) — the RunnerCore mutation-testing pilot: what a run costs and finds
- [mutation-trend.md](mutation-trend.md) — how to read a series of mutation runs
- [mutation-triage.md](mutation-triage.md) — the protocol that turns mutation survivors into tests

## History

- [archive/](archive/) — finished-era documents; nothing there describes current behaviour. Among them: the Pyodide-to-xeus migration (`xeus-python-grading-*`), the RunnerCore wasm migration, the language-handling review, the 2026-08 UI consistency audit, the editor freeze investigation, the 2026-10 abstraction survey, the per-language kernel postmortems and the CI flake history
- `CHANGELOG.md` (from 0.5.0) and `CHANGELOG-0.4.md` (0.1.0 to 0.4.x), at the repository root — release history
