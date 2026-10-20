### Changed

- **One shared grep-guard helper; no ratchets at zero (#2722).** The grep
  guards use `code_matches` from `scripts/lib/grep-guard.sh`. The layering and
  `alert()` rules are absolute, and the empty layering baseline is gone. The
  `ui-guard` agent is gone: run `lint-guard` and `test-runner`. The three
  Python hooks share `hook_common.py`. `deploy/README.md` names
  `server-deploy.sh` as the fallback, not the update step.
