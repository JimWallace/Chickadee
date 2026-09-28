# Submitting from GitHub

**Status:** slices 1 to 5 are built: an admin can register the GitHub App on
the admin GitHub page (Integrations → GitHub), a student can link a GitHub
account on the account page, a student can submit a commit from a repository
they own, a course can give each student a private repository in a course
organization, made from a template, and staff can see the last push to each
course repository. They are built so that the privacy review
(slice 0) can examine working behaviour. No deployment may register an App, and
no course may use any of it, until the review finishes. The section "What
reaches GitHub" lists every item of data that crosses, by slice. See
"Privacy".

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

As built (slice 4): the admin page's *Owner and permissions* disclosure has an
*Allow course repositories* checkbox. Only when it is on does the manifest ask
for the two slice-4 permissions. An App made without them can be given them
later on GitHub; until then, every course-repository call fails with a GitHub
error on the page. The admin page does not yet say whether the registered
App has them, because the choice is not stored at registration.

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

As built (slice 3): the steps are on a separate page,
`/testsetups/:id/github`, and the upload form links to it with one line. A
separate page keeps the upload form free of GitHub calls, so a GitHub outage
cannot slow or break it. The page shows the same attempt and deadline chips as
the upload form. Choosing a repository or a branch reloads the page (a plain
GET form, with a *Show commit* button when scripts are off). The page shows the
head commit's short SHA, as a link to the commit, and the first line of its
message. It does not show when GitHub received the commit, because the API
gives no push time for a commit; the committer date is written by the student
and is not shown either. A student without a link is sent to the account page;
a student without the App installed gets an *Install on GitHub* button, and
GitHub returns them to the same page (`/github/installed`, the setup URL in the
slice-1 manifest). Every error is one sentence in a `.form-error` banner, and
every error the student cannot fix points to the upload form.

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

As built (slice 3):

- The page resolves the branch to a SHA, and the form posts that SHA. So the
  student submits exactly the commit they saw, even if they push again before
  they click. The POST accepts only a 40-character hexadecimal SHA.
- The POST runs `requireOpenStudentAssignment` (the upload form's gate:
  enrolment, open state, deadline, extensions, a class activity's window)
  **before** any GitHub call, so a slow download cannot move the deadline.
- The ownership check reads the repository by its numeric ID and compares its
  `owner.id` with the linked GitHub user ID. The page also lists only owned
  repositories, but the check on the POST is the control.
- The installation must be on the linked account: the installation found for
  the linked login must report the linked GitHub user ID. A login that moved
  to another account therefore fails as "not installed".
- The save goes through `recordStudentSubmission`, the helper the upload form
  now uses too, so attempt numbers, diagnostics, the first-to-submit award and
  the local-runner start cannot drift between the two.
- Each GitHub submission is logged with the submission ID, the repository ID
  and the SHA. Tokens are never logged.
- The GitHub calls are closures on the Application (`GitHubRepoClient`), so
  tests use a fake and never reach the network.

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

As built (slice 3): `gzip -dc` runs with a cap on its output (40 MB, four times
the file limit, which leaves room for the 512-byte headers and padding of a
repository with many small files), so a compressed bomb stops at the cap. A
small tar reader in Swift then reads the result in memory. It keeps regular
files only (hard links, devices and FIFOs are dropped as well as symbolic
links), reads long names from pax `path` records and GNU `L` headers, drops any
name with a `..` or `.` component or an absolute path, and counts file bytes
against the 10 MB limit. The files are written to a temporary directory and
zipped with the same `zip` call the rest of the server uses. A commit with no
files is refused. No link is ever created on disk.

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

As built (slice 3): the field is `githubSubmission: true`, written only when
on, so every other manifest keeps its bytes. `makeWorkerManifestJSON` threads
it, so a suite edit does not turn it off, and `runnerSanitized` drops it. An
instructor turns it on with a checkbox in the edit page's *Student Options*,
which has its own endpoint (`POST /instructor/:id/github-submission`, audited
as `github.submission_toggled`) so a change during term does not close or
re-validate the assignment. The checkbox shows only while an App is registered
and only on a worker-graded assignment. `GitHubSubmissionOffer` is the one
predicate for "this assignment offers GitHub submission": the flag, worker
grading, and a registered App. The upload form's link and every GitHub route
ask it, and every GitHub route is 404 while it is false. The results page, for
the student and for staff, shows "From GitHub: owner/name at abc1234" with a
link to the commit.

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

As built (slice 4):

- **The course page** is `/instructor/github`. It has no tab, because the tab
  bar must not change while no App is registered; the GitHub note in an
  assignment's Student Options links to it. Course staff can read it; only a
  per-course instructor can change it. Every route is 404 while no App is
  registered.
- **Binding** proves two things, because typing an organization's name must
  not be enough: the App is installed on that organization, and the
  instructor's GitHub account is one of its owners. The instructor authorizes
  the App on GitHub (the same user authorization as account linking, and the
  same callback URL, told apart by the session's `state`). The server lists the
  installations that the user can reach (`GET /user/installations`), reads the
  user's role in the organization (`GET /user/memberships/orgs/{org}`, which
  needs the `members: read` permission), and **revokes the user token before it
  uses either answer**. The binding stores the installation ID, the
  organization ID and its login. It links no Chickadee account to GitHub.
- **Unbinding** removes only the binding. The repositories and their rows
  stay, so grades keep their commits.
- **Templates** are chosen per assignment, from the repositories the
  installation grants that GitHub marks as templates. A template that is not
  in that list is refused. A template puts the assignment in course-repository
  mode: the student submits only from the repository made for them, and the
  slice-3 list of the student's own repositories is not offered.
- **Making a repository is a button, not a page load.** The design above says
  "when a student first opens the assignment". As built, the student clicks
  *Make my repository* on the GitHub submit page. A GET must not make
  anything; GitHub limits how fast an App makes repositories, so a refusal
  must reach a person who can try again; and the student acts, so nothing is
  made in a student's name before they choose to use GitHub. There is no
  background retry: a refusal shows "GitHub is busy. Try again in a few
  minutes", and the upload form stays.
- **The repository** is `{assignment-slug}-{github-login}`, with any character
  GitHub does not allow replaced by `-`, private, in the bound organization.
  The student is invited with write (`push`) access. The row is saved before
  the invitation, so a failed invitation can be sent again (*Resend
  invitation*) without making a second repository.
- **Submitting** reads the course repository with the organization's
  installation token, not the student's. The ownership rule becomes "this is
  the repository made for this student": any other repository ID is refused
  as `notOwner`.
- **Forks.** The page reads the organization's
  `members_can_fork_private_repositories` setting and shows a warning when it
  is on. When the setting cannot be read, the page says so.
- **The end of term.** *Archive repositories* archives every course
  repository of the course that is not archived yet, and records the time.
  Nothing is deleted. It is not yet part of the course-archival flow.
- **Deletion.** Deleting a Chickadee user deletes their course-repository rows.
  The repository on GitHub stays, because it holds the commits a grade points
  at; an organization owner deletes it on GitHub if that is required.
- **The personal-data export** lists the student's course repositories.
- **Audit.** Binding, unbinding, a template change, a new course repository
  and archiving each write an audit entry in the GitHub category.

## Webhooks (slice 5, optional)

The MVP needs no webhooks: the student clicks *Submit*, and Chickadee pulls.
Webhooks help with two things only:

- Showing staff "last pushed" on the roster view, without a call per student.
- Refreshing the branch list without a call on each page load.

A push **never** starts a grading job by itself. If a push graded, each push
would use an attempt and a runner slot, and "which commit counts at the
deadline" would have no clear answer. A webhook needs a public inbound URL and
a check of the `X-Hub-Signature-256` header against the webhook secret.

As built (slice 5):

- **Opt-in.** The admin page's *Owner and permissions* disclosure has a
  *Receive push events* checkbox. Only then does the manifest carry
  `hook_attributes` (the URL `/github/webhook`) and the `push` event, and only
  then does GitHub make a webhook secret, which arrives with the other
  credentials and goes to `.github-app-secrets`.
- **The route** is `POST /github/webhook`, outside the session and CSRF
  middleware, because GitHub is the caller. It is 404 while no App with a
  webhook secret is registered. Every delivery must carry
  `X-Hub-Signature-256`, checked in constant time against the raw body;
  anything else is 401. Bodies over 5 MB are refused.
- **Only the branch list's other use was dropped.** The branch list on the
  submit page still reads GitHub on each load; a webhook-fed cache would store
  data the page needs for seconds.
- **A push** to a course repository records the server's time of receipt and
  the new head SHA on its row. A deleted branch, a push to any other
  repository, and every other event change nothing. Nothing is audited per
  delivery, because deliveries are frequent and carry no staff action.
- **What is discarded.** GitHub's push payload also carries the commit
  messages, the author and committer names and email addresses, and the
  pusher's login and email address. The route decodes the repository ID and
  the head SHA only; the rest is neither stored nor logged.
- **Where it shows.** The course GitHub page lists every course repository
  with its assignment, the student's name, and the last push as a relative
  time ("Not reported" before the first). Only course staff see that page.
- **What it does not handle.** A delivery is not deduplicated by
  `X-GitHub-Delivery`, and a replayed delivery would move the time forward. A
  replay needs a captured, signed request, which TLS prevents in transit; the
  effect is limited to a display time.

## Status checks (slice 6, opt-in)

An instructor can let Chickadee post a commit status with the **public** tier
result, for example "3/5 public tests passed". It never posts release or secret
tier results. It is off by default, because it puts a student's result on
GitHub. See "Privacy".

## Privacy

This is the real obstacle, and it is not a technical one. Slice 0 is a review
with the UW privacy office. It gates **turning the feature on**, not building
it: the built slices can merge while the review runs, because with no App
registered they change nothing (rule 1). No deployment registers an App, and
no course uses any slice, until the review finishes. Slice 4 was built before
the review so that the review can examine working behaviour rather than a
plan; its answers can still change the design, and the code changes with
them.

What changes:

- The student's code, commit history and GitHub login are on US-hosted GitHub.
  Today, all submission data stays inside the UW boundary (see
  `docs/compliance/trust-boundary.md`). See "What reaches GitHub" for the
  complete list, by slice.
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

### What reaches GitHub

This table is for the privacy review. It lists every item of data that crosses
between Chickadee and GitHub in the built slices, in which direction, and who
on GitHub can see it. "Out" is from Chickadee to GitHub; "In" is from GitHub to
Chickadee.

| Slice | Item | Direction | Who on GitHub sees it |
|---|---|---|---|
| 1 | The App manifest: the deployment's base URL and callback URLs, the App name, the permissions | Out | The admin who creates the App; the public App page shows the name and the homepage URL |
| 1 | The App ID, client ID, client secret, private key, webhook secret | In | Stored on the server only (the database and a 0600 file) |
| 2 | That a Chickadee user authorizes the App (the OAuth request itself) | Out | The student's own GitHub account |
| 2 | The student's GitHub user ID and login | In | Stored in `github_account_links`; the user token is revoked at once |
| 3 | The repository and branch names, the head commit's SHA and message | In | Read for the page only; not stored |
| 3 | The commit's files (tarball) | In | Stored as the submission zip, as an upload is |
| 3 | The repository ID, `owner/name` and the SHA of each GitHub submission | In | Stored on the submission row |
| 4 | That an instructor authorizes the App, and their role in the organization | Out, then In | The instructor's own account; the role is read once and not stored |
| 4 | The organization's ID and login, and the installation ID | In | Stored in `github_course_organizations` |
| 4 | A repository named `{assignment-slug}-{github-login}` | Out | **Every owner of the course organization, and every member who can see private repositories. The name contains the assignment's slug and the student's GitHub login.** |
| 4 | The template's files, copied into the student's repository | Out (GitHub to GitHub) | The same people |
| 4 | An invitation from the course organization to the student's GitHub login | Out | The student; the organization's owners |
| 4 | The repository ID and `owner/name`, and whether the invitation succeeded | In | Stored in `github_course_repositories` |
| 4 | The archived state at the end of term | Out | The same people as the repository |
| 5 | The deployment's webhook URL, in the App's settings | Out | The App's owner on GitHub |
| 5 | Push deliveries for course repositories: the repository ID and head SHA are kept; commit messages, author and committer names and emails, and the pusher's login and email arrive and are **discarded** | In | Stored: the time and the SHA on the course-repository row |

Nothing in slices 1 to 5 sends a grade, a test result, a Chickadee username,
a name, an email address or a student number to GitHub. The student's GitHub
login reaches the course organization only in slice 4, and only after the
student clicks *Make my repository*. Slice 5 is the one slice that receives
personal data Chickadee does not want: the push payload's names and email
addresses reach the server and are dropped at decoding.

## Operations

- Add `github` to `OutboundDestination`, so that the outbound-reachability
  health rule reports a GitHub outage correctly. Built in slice 3: only a
  transport error counts, so a 404 for a missing installation is not an outage.
- Cache installation tokens for their one-hour life. Do not get a new token for
  each request. Built in slice 3: kept in memory per GitHub account, and not
  used in the last five minutes before it expires.
- A GitHub outage stops GitHub submission only. The upload form still works.
  The submit panel must say this, and point the student to the upload form.
- Log the repository ID and the SHA on each GitHub submission. Do not log
  tokens.

## Slice plan

| Slice | Content | Visible change |
|---|---|---|
| 0 | Privacy review. Gates turning any slice on in a deployment. | None. |
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
