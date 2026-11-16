# Security Policy

Chickadee runs student code and holds student work and grades. We take reports
about its security seriously.

## Supported versions

Chickadee deploys continuously. Each green merge to `main` becomes a release
and reaches production. Only the latest release gets fixes. Please test
against the current `main` before you report.

## How to report

Do not open a public issue, discussion or pull request for a vulnerability.

Report it privately through GitHub:
<https://github.com/JimWallace/Chickadee/security/advisories/new>

Include:

- The component (server, runner, browser grader, deploy scripts, CI).
- The steps to reproduce, or a proof of concept.
- The effect you saw, and the effect you expect an attacker could get.
- The version or commit you tested.

## What to expect

- We acknowledge a report within five working days.
- We tell you if we accept it, and how we plan to fix it.
- We fix accepted reports in a release, then publish a GitHub security
  advisory. We credit you in it, unless you ask us not to.

Please give us a reasonable time to release a fix before you disclose.

## In scope

- The API server and web UI, including authentication, per-course roles,
  and the MCP servers.
- The runner and its sandbox: a submission that escapes it, reads another
  submission, or reads a hidden test.
- The browser grader, when it exposes data that the student must not see.
- The release and deploy pipeline: the GitHub Actions workflows, the image,
  and the scripts under `deploy/` and `scripts/`.

## Out of scope

- A bug in a vendored dependency (JupyterLite, a xeus kernel, a Swift
  package) that Chickadee does not make worse. Report it upstream. Tell us if
  Chickadee exposes it in a way that upstream does not.
- Volumetric denial of service.
- Findings from automated scanners without a demonstrated effect.
- Social engineering of staff or students.

## Safe harbour

We will not take action against research done in good faith under this
policy. Use your own accounts and test courses. Do not access, change or keep
the data of other users. Stop and report as soon as you reach real user data.
