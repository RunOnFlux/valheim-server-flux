# CLAUDE.md

A Docker packaging repo, not an application: `Dockerfile`, `scripts/flux-world-guard` (python3, stdlib only),
`scripts/flux-valheim-server` (wrapper that runs the guard, then execs the upstream script), tests, CI.

- Publishing `:latest` redeploys every server on it within about 6 h (FluxOS image update service). Never push to
  `main` or run the workflow without the owner's go-ahead.
- Never act on a chunk-level mismatch in the guard until the naming is verified on a populated world.
- `tests/test-image.sh` needs Docker and boots a real server (a few minutes).
