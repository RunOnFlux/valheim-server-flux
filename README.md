# valheim-server-flux

Valheim dedicated server image for [FluxCloud](https://runonflux.com/games/valheim). A thin layer over
the community Valheim server image
([community-valheim-tools/valheim-server-docker](https://github.com/community-valheim-tools/valheim-server-docker),
Apache-2.0): same game, same environment variables, same supervisor layout. Two things are different.

## 1. A base that only moves when we move it

Flux apps ran `lloesche/valheim-server:latest`, which is now a legacy mirror re-pushed on every upstream
release. FluxOS compares each app's tag digest every six hours and soft-redeploys the container when it
changes: players are kicked, and the owner sees "Rebuilding". That is the night-time drop in tickets such
as `valheim1792253596239`. This image pins the base by release tag, and CI publishes a new `:latest` only
when upstream cuts a release or an image input changes (`.github/ci/needs-rebuild.sh`). The game itself still
updates inside the container (`UPDATE_CRON`, steamcmd), so servers stay on the current Valheim build.

## 2. A world guard before every start (`scripts/flux-world-guard`)

Every Flux plan runs two instances of one world on a replicated volume. When the primary goes down, the
standby starts from its copy. If that copy is not a clean, complete save, Valheim 1.0 fails to parse the
folder and silently **generates a new world under the same name**, and its first save deletes the real one.
The guard runs in front of the server on every launch (first start, the daily restart, a restore) and, for
`worlds_local/$WORLD_NAME/` only:

1. moves `*.sync-conflict-*` files to `/config/sync-conflicts/` (kept, never deleted);
2. checks that the newest save (`_main.N.ok`) has its `.fwl2`, `.db2` and `.chunks`;
3. if not, moves that generation aside so the newest complete older one, whose chunks are all present, loads;
4. if nothing is complete but the folder holds save data, **refuses to start** (status 3, loud log) rather
   than let a fresh world be generated over it.

A new or empty world, a lone `_main.0.fwl2`, and a pre-1.0 `.db`/`.fwl` pair are left alone. Chunks listed by
the index but missing from the folder are logged and never acted on: the file naming was verified on a
one-chunk world, and a guard must not stop a healthy server on a guess.

It replaces nothing: the existing `PRE_SERVER_RUN_HOOK` env var, which the hub sets on servers today, still runs
next to it.

## Tests

```bash
python3 -m unittest tests.test_guard -v                       # the guard's logic, no docker
docker build -t valheim-server-flux:local .
./tests/test-image.sh valheim-server-flux:local [cache-dir]   # a real server: healthy, conflict, mixed, broken
```

## License

The base image is Apache-2.0. See `LICENSE`.
