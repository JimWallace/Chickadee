# Changelog fragments

Each PR drops **one new file** here instead of editing `CHANGELOG.md` directly.
New files never collide, so two PRs in flight at once no longer conflict on the
changelog (the old #1 source of merge thrash).

## How to add a fragment

Create `changelog.d/<something-unique>.md`. Use your branch name, the issue/PR
number, or a short slug so it's unique — e.g. `changelog.d/sso-reauth.md`.

The file is a snippet of Markdown that will be dropped, verbatim, under the next
release's version heading. Lead with a `### <Category>` line so it lands in the
right group, then your bullet(s):

```markdown
### Security

- **Short title.** One or two sentences on what changed and why.
```

Categories follow [Keep a Changelog](https://keepachangelog.com/): `Added`,
`Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`. If you omit a `###`
heading the bullet still lands, just ungrouped.

## What you do NOT touch anymore

- **`VERSION`** — assigned automatically at merge time.
- **`Sources/Core/ChickadeeVersion.swift`** — bumped automatically.
- **`CHANGELOG.md`** — assembled automatically from these fragments.

Leaving those three files alone is what stops concurrent PRs from colliding.
The merge-time `auto-release` workflow computes the next version, folds every
fragment in this directory into a new `CHANGELOG.md` section, deletes the
consumed fragments, and tags the release.

Run `scripts/assemble-release.sh --dry-run` locally to preview the section your
fragments will produce.
