# Sync fork with upstream main

- [x] Fetch `fork`, `origin`, and `upstream` refs.
- [x] Confirm the divergence is upstream history rewrite plus fork-only local commits.
- [x] Rebase `main` onto current `upstream/main`, preserving fork-only work.
- [x] Resolve any conflicts with minimal changes.
- [x] Run relevant verification.
- [x] Push corrected `main` to `fork`.
