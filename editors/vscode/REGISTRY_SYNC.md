# Keeping `server/registry` in Sync

`server/registry` is not source. It is a build artifact: a full copy of the
repository's `stdlib/registry` staged at build time. It is listed in
`.gitignore`, so it never enters version control and never needs manual
maintenance.

## How the copy happens

`scripts/install-server.sh` is the only place that writes `server/registry`.
It removes the old tree and copies the current one outright:

```sh
rm -rf "$here/server/registry"
cp -R "$repo/stdlib/registry" "$here/server/registry"
```

Because the whole tree is replaced, there is no incremental drift and no
stale package left behind.

Two entry points already run that script:

- **Packaging:** `scripts/build-vsix.sh` calls `install-server.sh` before
  bundling, so every `.vsix` carries the `stdlib/registry` as it stood at
  packaging time.
- **Debugging:** `.vscode/tasks.json` runs
  `npm run build && bash scripts/install-server.sh` as the `preLaunchTask`,
  so every F5 launch restages the server and the registry.

## What you need to do

- After changing `stdlib/registry`, package with
  `bash scripts/build-vsix.sh`. Do not run `vsce package` on its own — that
  would ship the snapshot left by the previous staging run.
- After changing `stdlib/registry`, to test against an installed extension,
  rerun `bash scripts/install-server.sh`, or launch with F5, which reruns it
  for you.
- The same applies after switching branches or pulling: `server/registry`
  does not update itself; it is whatever the last script run copied.

## Development against the live tree

To see registry edits immediately without restaging, point `emo.registry` at
the live directory in workspace settings:

```json
{ "emo.registry": "/path/to/emo/stdlib/registry" }
```

`src/extension.ts` resolves the endpoint in this order:

1. the `emo.registry` setting
2. the `EMO_REGISTRY` environment variable
3. the bundled `server/registry`, when it exists

This is a development convenience only. The published extension must stay
self-contained, so the staged copy is required for packaging; do not replace
`server/registry` with a symlink, as the `.vsix` needs real files.

## Scope

`emo.registry` only affects completion and dependency resolution for
registry packages. The standard library itself is embedded in the
`emo-lsp` binary, so editing standard-library sources without touching
`stdlib/registry` leaves the staged copy correctly untouched.
