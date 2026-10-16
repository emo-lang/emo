# Package Management

Packages slot directly into the module system: a package name becomes a top-level module path prefix. There is no `install` step for libraries — dependency resolution is a side effect of building. Using a package is `require`:

```emo
require "acme/json_tools"

def parse_config(text String) json_tools.Json {
  return json_tools.parse(text)
}
```

- **`require` is a file-level statement that brings the package's short name into scope.** It needs no counterpart on the package side — a package's public surface is simply its module tree. Fully qualified paths are always available.
- **A package's module tree is mounted under its short name.** The package root's `<short>.emo` is the module `<short>` a `require` binds; every other file or directory is a child of it — `plot/internal/svg.emo` is `plot.internal.svg`, `plot/mark.emo` is `plot.mark` — so two packages' `internal` and `mark` never collide. Inside the package, references are written against the package root (`internal.scale` in `plot.emo` means `plot.internal.scale`), so a package compiles the same whether built alone or mounted under its prefix.
- **The standard library needs no manifest entry; a third-party package does.** The official standard library owns the top-level short names (`json.decode()`, `http.get(url)`) and ships with the compiler, so `require "json"` resolves implicitly — including the standard-library packages that dependency pulls in. A scoped package (`acme/json_tools`) must be pinned in `deps`: requiring one that is missing is a compile error — strictness comes first, and the manifest changes only by explicit action.

- **A package is rooted where you stand.** The root is the working directory, and it must hold `package.emo` — the compiler never looks upward, so a command started in a directory without one stops with E5010 (``run `emo new <name>` to scaffold a project here``), and an entry that is not a module of the package rooted there is E5011. `cd` into the package first: that directory is the module tree, and every command reads it from there, so the same file means the same thing wherever the command was typed.

- **Central registry, with configurable endpoints.** Packages are addressed by `name@version` through a central registry, backed by a global content-addressed cache shared across projects — no per-project dependency copies. The endpoint a project pulls from is chosen by, in order: the `EMO_REGISTRY` environment variable, the manifest's optional `registry` field, then the standard library's bundled registry shipped with the compiler. The field takes an `http(s)` URL only — a committed manifest must name an endpoint every machine reaches the same way, so a filesystem registry (a directory the protocol's bare-file layout is exported into) stays an `EMO_REGISTRY`-only affair for tests and offline development. An HTTP registry serves scoped (`owner/name`) packages; the top-level short names belong to the standard library and always resolve from the bundled copy, even with a remote registry configured. A yanked version is excluded from fresh resolution but stays downloadable, so an existing `package.lock` keeps installing. Every fetch verifies the content digest against the lockfile (or the registry's own advertised checksum on a fresh resolve) — a mismatch is an error, never a silent swap.
- **Scoped package names.** Third-party packages are named under a scope prefix, so ownership is explicit and name squatting has no ground to stand on; the scope prefix becomes the module path prefix. The official standard library alone owns the top-level short names (`json.decode()`, `http.get(url)`).
- **The manifest is an Emo config file**, written in the restricted profile (terminating, hermetic, side-effect free). No reader ever walks it as a module: dependency resolution, `emo publish`, `emo check`, and the editor's diagnostics all read it in this profile, and a command that needs a program refuses it — `emo run` and `emo build` exit 66 on a `package.emo` entry instead of reading its fields as code. **Dependencies are exact versions** — the version a package is developed and tested against — and **targets declare which compilation targets the package supports**. A package that binds native code also names the system libraries it links in the optional `link` field, and a project that pulls from a non-default registry names it in the optional `registry` field:

  ```emo
  package {
    name = "acme/json_tools"
    version = "0.1.0"
    targets = ["ocaml", "wasm"]
    link = ["sqlite3"]
    registry = "https://packages.example.com"

    deps {
      "json" = "2.3.1"
      "http" = "1.4.2"
    }
  }
  ```

  The `registry` field is read only when the manifest is the project root — a dependency's manifest is fetched from the registry its consumer already chose, so its field is ignored there, and `emo publish` keeps picking its endpoint from `--registry`, `EMO_REGISTRY`, or the stored login.

- **A `deps` key is a string literal** — the block's one spelling. A package name is data here as it is everywhere else (the `name` field, `require`, the lockfile, the registry), so what a scope may be called does not depend on the lexer: an owner that is a keyword (`emo`) or carries a hyphen is writable. The package fields (`name`, `version`, `targets`, `link`, `registry`) stay identifier bindings — a fixed schema of fields on one side, a name→version map on the other.

- **A package may carry native code.** `.c` and `.h` files in a package's tree are part of the package — collected, checksummed, and published beside its `.emo` modules. The `c` target compiles a dependency's C sources into the program and links the libraries its `link` field names, so consuming a native-binding package like `sqlite3` is just `require` — no `--cclib`, no manual shims. The `link` field takes bare library names only. Only the `c` target honors a package's native inputs; every other target refuses such a dependency at build time, and the manifest's `targets` refuses it at resolution.

- **Versions are semantic (major.minor.patch), resolved by Minimal Version Selection (MVS).** When different packages require different versions of the same dependency, the smallest version satisfying every requirement wins — for exact requirements, the highest one named. Upgrades are always explicit actions. The lockfile (`package.lock`) records the resolution with checksums and belongs in version control; `emo deps resolve` writes it, `emo deps update` regenerates it after a pin changes, `emo deps list` reads it — building never rewrites it silently. A checksum is the SHA-256 over the package's collected sources (`.emo`, plus any `.c`/`.h`), sorted by path and fed as `path \0 content \0` — the same digest the registry recomputes on publish. (Checksums were MD5 before the registry protocol froze; a lockfile written by an older compiler should simply be deleted and re-resolved.)
- **Target compatibility is checked at resolution time.** A dependency that does not support the target being built fails resolution with a clear error, not midway through compilation.
- **Publishing is `emo publish`, run from the package root.** The command validates the manifest (an `owner/name` name, a well-formed version), packs every collected source — `.emo` and any `.c`/`.h`, subdirectories included — plus an optional root `README.md` into a deterministic `.emoji` archive (gzip tar, sorted paths, zeroed metadata: the same input always packs to the same bytes), and POSTs it to the registry. The endpoint comes from `--registry`, `EMO_REGISTRY`, or the most recent `emo emoji login`; the API token from `--token`, `EMO_TOKEN`, or the stored login for that registry — a stored token is only ever sent to the registry it was minted for. `--dry-run` validates and packs locally, printing the archive name, size, checksum, and file list without uploading. Versions are immutable: publishing an existing version is rejected — bump `version` in the manifest.
- **The shared-package lifecycle is `emo emoji`** — the group named after the archive format itself. `emo emoji new acme/string_tools` scaffolds a publishable package (an `owner/name` manifest, the public module named after the package, a README); `emo emoji build` compiles the package's entry module under every declared target — the pre-publish gate; `emo emoji login` verifies your account against a registry and stores a push/yank/read API token in `~/.config/emo/credentials` (0600, one block per registry, the expiry recorded alongside it — `--expires-in-days` bounds the token's life), so publishing afterwards needs neither flags nor environment — with a terminal it asks for the email and password (the password read with the echo off), otherwise it reads them as two lines from stdin; when a stored token has expired, the registry refuses it with a dedicated code and `emo publish` points back to `emo emoji login`; `emo emoji publish` is the same upload as `emo publish`.
