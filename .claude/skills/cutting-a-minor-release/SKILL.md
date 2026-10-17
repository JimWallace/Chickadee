---
name: cutting-a-minor-release
description: >
  Cuts a minor (0.y.0) or major Chickadee release by hand with
  scripts/assemble-release.sh --version, and says which changes must wait for
  one. Use when the maintainer asks for a minor or major release, or when a
  pull request removes a compatibility surface (a route, an environment
  variable, a wire field) or asks to bump the version. Patch releases are
  automatic on merge.
---

# Cutting a minor release

Auto-release makes only patch releases, by construction. No sequence of merges
can make a minor release. A minor release is a deliberate decision by the
maintainer, so do not start one on your own judgement.

The reference is [docs/release-process.md](../../../docs/release-process.md):
§"What the numbers mean while we are 0.y.z" says what each number means, and
§"Cutting a minor (or major) release" holds the steps.

## When it is a minor, not a patch

A patch never removes or breaks a compatibility surface: an environment
variable, a route, a wire field, a bundle key or a stored format. A pull
request that retires one of those waits for the next minor, where the removals
land together. A major release is reserved, and the deployer holds it for an
operator's approval.

For such a pull request: keep the surface on patches, with a deprecation
warning, and tell the maintainer that the removal waits for the next minor. Do
not merge the removal as a patch, and do not start the minor yourself.

A pull request never bumps the version itself. It adds one `changelog.d/`
fragment (`CLAUDE.md` §"Versioning").

## Workflow

Copy this checklist and complete it in order:

```
Release progress:
- [ ] 1. The maintainer asked for this release, and named the version
- [ ] 2. Local main is up to date with origin/main
- [ ] 3. At least one fragment is in changelog.d/ (write a milestone note)
- [ ] 4. Preview: scripts/assemble-release.sh --dry-run
- [ ] 5. Run: scripts/assemble-release.sh --version X.Y.0
- [ ] 6. Review the diff: VERSION, ChickadeeVersion.swift, CHANGELOG.md
- [ ] 7. Commit with the exact message prefix chore(release): vX.Y.0
- [ ] 8. Make an annotated tag, then give the push to the maintainer
```

**Step 3.** The script refuses an empty fragment set, with `--version` or
without it.

**Step 7.** The `chore(release):` prefix stops `auto-release.yml` from
cutting a redundant `X.Y.1` on the same push. Any other message cuts one.

**Step 8.** A tag that a workflow pushes with `GITHUB_TOKEN` does not start
`release.yml` or the Docker tag build. The maintainer pushes `main` and the tag
from their own account. Make the tag, then give them the push:

```
git tag -a vX.Y.0 -m "Chickadee vX.Y.0"
git push origin main vX.Y.0
```

After the push, the deployer deploys a minor release with no approval, and
auto-release continues at `X.Y.1` on the next merged fragment.
