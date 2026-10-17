---
name: cutting-a-minor-release
description: >
  Cuts a minor (0.y.0) or major Chickadee release by hand with
  scripts/assemble-release.sh --version. Use only when the maintainer asks
  for a minor or major release, an era boundary, or a batch of compatibility
  removals. Patch releases are automatic on merge and do not use this skill.
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
- [ ] 8. Tag vX.Y.0, then give the push to the maintainer
```

**Step 3.** The script refuses an empty fragment set, with `--version` or
without it.

**Step 7.** The `chore(release):` prefix stops `auto-release.yml` from
cutting a redundant `X.Y.1` on the same push. Any other message cuts one.

**Step 8.** A tag that a workflow pushes with `GITHUB_TOKEN` does not start
`release.yml` or the Docker tag build. The maintainer pushes `main` and the tag
from their own account. Give them the commands, one plain command per line:

```
git push origin main
git push origin vX.Y.0
```

After the push, the deployer deploys a minor release with no approval, and
auto-release continues at `X.Y.1` on the next merged fragment.
