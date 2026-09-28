# Submitting from GitHub

**Status:** slices 1 and 2 are built: an admin can register the GitHub App on
the admin GitHub page (Integrations → GitHub), and a student can link a GitHub
account on the account page. Nothing submits from GitHub yet. Slices 1 to 3 can
be built before the privacy review (slice 0) finishes, but no deployment may
register an App until it finishes. See "Privacy".

This note tells how a student can submit to Chickadee from a GitHub repository,
and how a course can give each student a private repository made from a
template. It also tells which existing features stay as they are. The goal is
**additive** support: a deployment that registers no GitHub App behaves exactly
as it does today, and an assignment that does not turn on GitHub submission
shows no GitHub control.

The request came from an instructor who chose GitHub Classroom over Chickadee
for its GitHub integration.

## Terms

| Term | Meaning here |
|---|---|
| GitHub App | One app registration on GitHub for one Chickadee deployment. It has a numeric App ID, a private key and a webhook secret. |
| Installation | One installation of the App on one GitHub account or organization. The App can read only the repositories that an installation grants. |
| Installation token | A token that the App gets for one installation. It expires after one hour. |
| Linked account | The GitHub account that a Chickadee user proved they own. |
| Student-owned repository | A repository that the student made in their own GitHub account. |
| Course repository | A repository that Chickadee made for one student, in a course organization, from a template. |
| Source commit | The commit SHA that one submission was made from. |

## What GitHub Classroom does

| Classroom feature | In this design |
|---|---|
| An invitation link makes a private repository for each student from a template. | Slice 4, course repositories. |
| A roster maps students to GitHub accounts. | Slice 2 (linked accounts). Chickadee already has the roster. |
| Autograding runs as GitHub Actions in the student repository. | **Not replicated.** Chickadee grades on its own runners. See below. |
| A "feedback" pull request lets staff comment on code. | Out of scope. |
| An LMS integration imports the roster. | Chickadee already has BrightSpace sync and LTI 1.3. |

### Why grading stays on Chickadee

Classroom autograding runs the tests inside the student repository. The student
can read those tests, and the student can change the workflow file. Chickadee
keeps the release and secret tiers on the server, and the runner fetches them
for each job. A commit from GitHub must go through the same runner as an upload.
It must not go through GitHub Actions.

This is also why the change is small: after intake, a GitHub submission is an
ordinary submission zip. The runner, `RunnerCore`, the tiers, the results pages,
slip days and the grade of record do not change.

## Compatibility rules

Each slice must obey these rules.

1. **No App, no change.** When no GitHub App is registered, no GitHub route
   accepts a request, and no page, header, cookie or sweep changes.
2. **No new environment variables.** The standing rule in `CLAUDE.md` applies.
   See "App credentials" below.
3. **Upload stays.** GitHub is a second way to submit, beside the upload form.
   An assignment never requires GitHub. A student without a GitHub account
   must always have a way to submit. See "Privacy".
4. **Grading does not change.** A GitHub submission becomes a zip in
   `submissionsDirectory`, with `kind == student`. The worker protocol, the
   manifest and the runner do not change. An old runner can grade a GitHub
   submission.
5. **The deadline is the server's clock.** Chickadee uses the time that it
   received the submit request. It never uses a commit date, because a student
   can set a commit date to any value.
6. **Nothing goes back to GitHub by default.** Chickadee does not post status
   checks, comments or scores to GitHub unless a slice-6 opt-in says so.
7. **Additive schema only.** New tables and nullable columns. No existing column
   changes meaning.

## App credentials

### Creating a GitHub App

Creating a GitHub App is easy. There are two ways:

- **By hand.** An organization owner opens *Settings → Developer settings →
  GitHub Apps → New GitHub App*, fills in a form (name, homepage URL, callback
  URL, webhook URL, permissions), then clicks *Generate a private key*. This
  takes about ten minutes. The result is five values: the App ID, the client ID,
  the client secret, the webhook secret, and a private key as a multi-line PEM
  file.
- **With the manifest flow.** Chickadee builds a JSON manifest with the correct
  URLs and permissions. An admin clicks one button, which sends the manifest to
  GitHub. GitHub shows the admin a confirmation page. The admin clicks *Create*.
  GitHub redirects back to Chickadee with a temporary code, and Chickadee
  exchanges that code (`POST /app-manifests/{code}/conversions`) for all five
  values in one response. The admin copies nothing.

### Where the values live

**Recommendation: the manifest flow, and no environment variable.**

- The App ID, the App slug and the client ID are not secret. They go in a
  `github_apps` table with at most one row.
- The private key, the client secret and the webhook secret go in
  `.github-app-secrets` in the working directory, mode 0600. This is the same
  pattern as `.lti-tool-key` and `.worker-secret`.

As built (slice 1): the admin page at `/admin/github` posts the manifest to
GitHub, for the admin's own account or for an organization. The callback
(`/admin/github/callback`) accepts only the `state` that the same session sent,
exchanges the code once, writes `.github-app-secrets` (created with mode 0600)
and then the row. If the row cannot be saved, the file is removed again. The
manifest asks for read access to contents and metadata, sets no webhook, and
already names the slice-2 callback URL and the slice-3 setup URL, so an admin
does not have to edit the App later. *Remove registration* deletes the row and
the file; the App itself stays on GitHub until an admin deletes it there.

An environment variable was considered. These are the reasons not to use one:

1. There are five values, not one. One of them is a multi-line PEM, which is
   difficult to put in `.env`, in `docker-compose.yml` and in a systemd unit.
2. The manifest flow makes the values arrive at the server directly. With an
   environment variable, an operator must copy each value by hand into each
   place that starts the server. This is the failure mode that the
   no-new-variables rule exists to prevent.
3. "No row, no feature" is the natural off switch (rule 1). An environment
   variable needs a separate rule for "set but empty".
4. LTI 1.3 made the same choice for the same reasons (`docs/lti-1-3.md`,
   compatibility rule 2).

The BrightSpace app credentials (`BrightSpaceAppCredentials.fromEnvironment()`)
are a counter-example. They were added before the rule, and they are one short
ID and one short key.

### Permissions

The App asks for the minimum:

| Permission | Level | Why |
|---|---|---|
| Repository contents | Read | Download the tarball of the source commit. |
| Repository metadata | Read | Required by GitHub for every App. |
| Repository administration | Write | **Slice 4 only**: make course repositories from a template. |
| Organization members | Read | **Slice 4 only**: invite a student to their course repository. |

The App does not ask for a user's email, for Actions, or for write access to
contents. A deployment that stops at slice 3 never asks for the slice-4
permissions.

## Linking an account (slice 2)

The account page gets a *Link GitHub account* button. It starts the GitHub App
user authorization flow (OAuth with PKCE). Chickadee reads the authenticated
user from `GET /user`, keeps two values, and discards the user token:

- `github_user_id`: the numeric ID. This is the identity.
- `github_login`: the login name. This is for display only, because a user can
  rename their account.

A new table `github_account_links` holds one row per Chickadee user, with
`github_user_id` unique. One GitHub account can not link to two Chickadee users.
*Unlink* deletes the row. The student can unlink at any time.

As built (slice 2):

- The account page shows a GitHub section only when the student can link an
  account (an App is registered and `PUBLIC_BASE_URL` is set) or already has a
  link. With no App, the page is unchanged.
- *Link GitHub account* posts to `/account/github/link`, which stores a
  single-use `state` and a PKCE verifier in the session and redirects to
  GitHub's authorize page with `allow_signup=false`. The account page adds
  `https://github.com` to its `form-action`, because Chromium checks the
  redirect against the page that holds the form.
- The callback (`/github/link/callback`, the URL the slice-1 manifest
  registered) accepts only that `state`, exchanges the code with the client
  secret and the verifier, reads `GET /user`, and **revokes the user token at
  once**. Nothing that can act on the student's GitHub account stays on the
  server.
- Linking again replaces the student's link. A GitHub account already linked
  to another Chickadee account is refused.
- Linking and unlinking are audited. The link appears in the student's data
  export (`profile.githubAccount`), and deleting a user deletes their link.

## Submitting a commit (slice 3, the MVP)

### The student side

The submit page of a GitHub-enabled assignment shows a second panel beside the
upload form:

1. The student selects a repository. The list is the repositories that the
   student's installation grants and that the linked account owns.
2. The student selects a branch. Chickadee shows the head commit: SHA, message
   and the time that GitHub received it.
3. The student clicks *Submit commit abc1234*.

A student installs the App on their own account once, and grants it only the
repositories they select. GitHub shows this step.

### The server side

1. Check that the linked account **owns** the repository: the repository
   `owner.id` must equal `github_user_id`. Without this check, a student can
   submit a classmate's repository that the classmate granted to the App. In
   slice 4, the check is instead "this is the course repository made for this
   student".
2. Resolve the branch to a SHA once. Everything after this uses the SHA, so a
   push during the request does not change what is graded.
3. Get an installation token, and download
   `GET /repos/{owner}/{repo}/tarball/{sha}`.
4. Convert the tarball to the submission zip (see below).
5. Save the submission through the same code that the upload form uses, with
   the caller as `userID`. Deadline, slip-day, attempt-number and
   accepted-file checks run exactly as for an upload.

`POST /api/v1/submissions` can not be reused: it saves `userID: nil`
(`Sources/APIServer/Routes/SubmissionRoutes.swift`). The GitHub path must
attribute the submission like the web path does.

### Converting the tarball

GitHub's tarball has one top-level directory, `{owner}-{repo}-{sha}/`. The
conversion:

- Removes that top-level directory, so the files sit at the zip root as they
  do in an upload.
- Refuses the submission when the unpacked size is more than the upload body
  limit (`defaultMaxBodySize`, 10 MB). It counts bytes while it reads, so a compressed bomb stops early.
- Drops symbolic links. An upload can not contain one, and a link can point
  outside the workspace.
- Does not follow submodules. The tarball does not include them.
- Keeps Git LFS pointer files as they are. It does not fetch LFS objects.

The student sees each refusal as a `.form-error` banner, in the same words as
the upload refusals.

### What is stored

New nullable columns on `submissions`:

| Column | Meaning |
|---|---|
| `source_kind` | `upload` or `github`. Nil on old rows means `upload`. |
| `source_repo_id` | The numeric GitHub repository ID. |
| `source_repo_name` | `owner/name` at the time of the submit, for display. |
| `source_commit` | The full 40-character SHA. |

The results page and the staff submission page show the short SHA as a link to
the commit on GitHub. The diff page between two attempts works as it does now,
because it compares the zips.

### Which assignments

An assignment turns GitHub submission on with a manifest field, beside
`submissionMode`. Only the native-worker path uses it:

- **Upload-only languages (C++, Java, Racket) and plain `.sh` suites.** A good
  fit. These are the multi-file projects that students keep in Git.
- **Notebook assignments.** Not offered. The work already lives in the
  JupyterLite editor, and a browser-graded submission starts from the notebook
  page.

The manifest field must reach the worker manifest through
`makeWorkerManifestJSON` or be excluded from it on purpose. The runner does not
need it, so `runnerSanitized` should strip it.

## Course repositories (slice 4)

This slice is the Classroom feature: each student gets a private repository in
a course organization, made from the instructor's template.

1. An instructor installs the App on the course organization, and binds the
   installation to the Chickadee course.
2. On the assignment page, the instructor selects a template repository.
3. When a linked student first opens the assignment, Chickadee makes
   `{org}/{assignment-slug}-{github-login}` from the template, private, and
   invites the student as a collaborator with write access. A new table
   `github_course_repositories` maps (assignment, student) to the repository ID.
4. The submit panel shows only that repository.

Things to handle:

- **Rate limits.** GitHub limits how fast one App can make repositories. Make
  them when a student first opens the assignment, not all at once for the
  roster. A background retry handles a refusal.
- **Forks.** The organization setting must refuse forks of private
  repositories, or a student can make a public copy. Chickadee should show
  this setting on the binding page and warn when it is off.
- **Name changes.** The mapping uses the repository ID, so a rename does not
  break it.
- **The end of term.** Archive the repositories. Do not delete them, because
  the grade of record points at their commits. The course-archival flow
  should offer this.

## Webhooks (slice 5, optional)

The MVP needs no webhooks: the student clicks *Submit*, and Chickadee pulls.
Webhooks help with two things only:

- Showing staff "last pushed" on the roster view, without a call per student.
- Refreshing the branch list without a call on each page load.

A push **never** starts a grading job by itself. If a push graded, each push
would use an attempt and a runner slot, and "which commit counts at the
deadline" would have no clear answer. A webhook needs a public inbound URL and
a check of the `X-Hub-Signature-256` header against the webhook secret.

## Status checks (slice 6, opt-in)

An instructor can let Chickadee post a commit status with the **public** tier
result, for example "3/5 public tests passed". It never posts release or secret
tier results. It is off by default, because it puts a student's result on
GitHub. See "Privacy".

## Privacy

This is the real obstacle, and it is not a technical one. Slice 0 is a review
with the UW privacy office. It gates **turning the feature on**, not building
it: slices 1 to 3 can merge while the review runs, because with no App
registered they change nothing (rule 1). No deployment registers an App, and
no assignment turns GitHub submission on, until the review finishes. Slice 4
and later wait for the review, because its answers can change their design.

What changes:

- The student's code, commit history and GitHub login are on US-hosted GitHub.
  Today, all submission data stays inside the UW boundary (see
  `docs/compliance/trust-boundary.md`).
- The student must accept GitHub's terms to make an account.
- Slice 4 puts a student's name, as their GitHub login, into a course
  organization that other staff can see.
- Slice 6 puts a result on GitHub.

What does **not** change: Chickadee sends nothing to GitHub in slices 1 to 3.
It only reads a repository that the student chose to grant, at a time the
student chose.

Questions for the privacy office:

1. Can a course offer GitHub submission when an upload path always stays
   available (rule 3)?
2. Does slice 4, where the course organization holds the repositories, need
   more than that?
3. Is a status check with a public-tier result (slice 6) acceptable, and with
   which consent?
4. Must the data-flow inventory (`docs/compliance/data-flow-inventory.md`)
   and the trust-boundary diagram show GitHub as a new third party?

## Operations

- Add `github` to `OutboundDestination`, so that the outbound-reachability
  health rule reports a GitHub outage correctly.
- Cache installation tokens for their one-hour life. Do not get a new token for
  each request.
- A GitHub outage stops GitHub submission only. The upload form still works.
  The submit panel must say this, and point the student to the upload form.
- Log the repository ID and the SHA on each GitHub submission. Do not log
  tokens.

## Slice plan

| Slice | Content | Visible change |
|---|---|---|
| 0 | Privacy review. Gates turning slices 1 to 3 on, and starting slice 4. | None. |
| 1 | `github_apps` table, the secrets file, the manifest flow, and an admin page to register and remove the App. | An admin page. |
| 2 | Account linking and unlinking on the account page. | A button on the account page. |
| 3 | The manifest field, the submit panel, the ownership check, tarball conversion and the `source_*` columns. **The MVP.** | GitHub submission for student-owned repositories. |
| 4 | Course organizations, templates and course repositories. | Classroom parity. |
| 5 | Webhooks, for display only. | "Last pushed" on the staff roster. |
| 6 | Opt-in public-tier status checks. | A status on the commit. |

Each slice needs its own tests. Slice 3 needs, at minimum: the ownership check
refuses a repository that the linked account does not own; the conversion
removes the top-level directory, drops symbolic links and refuses an oversized
tarball; a GitHub submission after the deadline is refused exactly as an upload
is; and the saved row has the caller's `userID`. The GitHub API calls go through
a protocol with a fake in tests, so no test needs the network.

## Out of scope

- Grading with GitHub Actions.
- Codespaces, and any GitHub-hosted editor.
- Feedback pull requests and code review on GitHub.
- GitHub Enterprise Server. The design uses only public API endpoints, so it
  may work, but nobody has tried it.
- Other forges (GitLab, the UW GitLab). The design should keep the forge behind
  one protocol, so another forge is a new implementation and not a new design.
