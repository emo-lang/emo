# The emo toolchain's build automation.
#
# The emo CLI itself is OCaml — dune is the one step that needs an
# OCaml toolchain, and everything downstream of it does not: the built
# binary carries the standard library inside it and its default build
# path is the c target, so an installed emo needs only the system cc.

default:
    @just --list

# Build the two executables in the release profile — `emo`, the CLI
# every other recipe installs or packages, and `emo-lsp`, the language
# server the editor integrations drive.
#
# build: compile the release binaries
build:
    dune build --profile release src/emo_cli/emo.exe bin/emo_lsp_bin.exe

# Install both release binaries into PREFIX (default ~/.local/bin) as
# symlinks to this tree's build output — the dev install: every `dune
# build` here refreshes the installed `emo` and `emo-lsp` immediately,
# no reinstall. The links ride the tree — moving or removing this
# checkout (or `dune clean`) breaks the pair until the next build here.
# The `emo` binary itself is still the standalone c-target build, where
# `emo build` afterwards needs only the system cc. Verify with
# `emo doctor`.
#
# install: install the release binaries as symlinks (PREFIX, default ~/.local/bin)
install PREFIX="$HOME/.local/bin":
    dune build --profile release src/emo_cli/emo.exe bin/emo_lsp_bin.exe
    mkdir -p {{PREFIX}}
    ln -sfn "{{justfile_directory()}}/_build/default/src/emo_cli/emo.exe" "{{PREFIX}}/emo"
    ln -sfn "{{justfile_directory()}}/_build/default/bin/emo_lsp_bin.exe" "{{PREFIX}}/emo-lsp"
    @echo "linked {{PREFIX}}/emo -> _build/default/src/emo_cli/emo.exe and {{PREFIX}}/emo-lsp -> _build/default/bin/emo_lsp_bin.exe — verify with: emo doctor"

# Build and install through the opam switch instead — the source
# install, which also brings the ocaml compilation target.
#
# install-dev: source install through the opam switch
install-dev:
    dune build
    dune install --bindir=$HOME/.local/bin emo

# Remove the dev install (the install-dev route is uninstalled
# through opam).
#
# uninstall: remove the installed emo and emo-lsp links
uninstall PREFIX="$HOME/.local/bin":
    rm -f {{PREFIX}}/emo {{PREFIX}}/emo-lsp

# Assemble the distributable release archive for this platform into
# dist/ — one platform, for quick checks; the release itself builds
# all three through devtools/build-release.sh.
#
# package: build the distributable archive into dist/
package:
    #!/bin/sh
    set -e
    case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) echo "unsupported platform: $(uname -s)" >&2; exit 65 ;;
    esac
    dune build --profile release src/emo_cli/emo.exe
    devtools/package-release.sh _build/default/src/emo_cli/emo.exe \
      "$(cat VERSION)" "$os" "$(uname -m)" dist

# Build a local Linux builder image — the one-time setup behind
# `just release`'s Docker builds. arm64 runs natively; amd64 under
# Rosetta. Rerun after devtools/release-builder.Dockerfile changes.
#
# release-image: build a Linux builder image (ARCH, arm64 or amd64)
release-image ARCH:
    docker build --platform linux/{{ARCH}} \
      -t emo-release:ubuntu22.04-{{ARCH}} \
      -f devtools/release-builder.Dockerfile .

# Notarize the release's macOS archive from this machine — the local
# half of the signing story; the archive is a dist file built by
# devtools/build-release.sh. Signs with the keychain's Developer ID
# Application identity, notarizes, and refreshes the dist's
# SHA256SUMS. Needs a notary credential: EMO_NOTARY_PROFILE
# (defaulting to emo-notary; see devtools/notarize-release.sh), the
# ASC key trio, or the Apple ID quartet.
#
# notarize: notarize the macOS archive in a dist dir (DIR, default dist)
notarize DIR="dist":
    #!/bin/sh
    set -e
    : "${EMO_NOTARY_PROFILE:=emo-notary}"
    export EMO_NOTARY_PROFILE
    if [ -z "$EMO_NOTARY_PROFILE" ] && [ -z "$EMO_NOTARY_KEY" ] && \
      [ -z "$EMO_NOTARY_APPLE_ID" ]; then
        echo "notarize: set EMO_NOTARY_PROFILE (xcrun notarytool store-credentials)," >&2
        echo "the ASC key trio (EMO_NOTARY_KEY/_KEY_ID/_ISSUER), or the Apple ID quartet" >&2
        exit 64
    fi
    devtools/notarize-release.sh {{DIR}}

# Publish a release's archives to the download site — the pipeline's
# last leg, after `notarize`. The archives are local files; the site
# is the only public download channel. See devtools/publish-release.sh
# for the knobs: EMO_RELEASE_HOST, EMO_RELEASE_STATIC_ROOT.
#
# publish: upload a release's archives to the download site (TAG, e.g. v0.26.8)
publish TAG DIST="dist":
    devtools/publish-release.sh {{TAG}} {{DIST}}

# Ship a release end to end from the signing Mac: cut the annotated
# tag at HEAD (must match a committed VERSION file), push the branch
# and the tag to AtomGit — the source host; nothing else observes the
# release — then build and test all three archives on this machine
# (macOS arm64 natively, both Linux architectures in Docker),
# notarize the macOS zip, and publish everything to the download
# site. No forge hosts any part of the pipeline. Run on the machine whose keychain
# holds the Developer ID identity, the emo-notary profile, and the
# SSH key the site accepts — with Docker Desktop up and both builder
# images built (just release-image arm64 / amd64).
#
# release: tag, build, notarize, and publish (TAG, e.g. v0.26.1018-alpha)
release TAG:
    #!/bin/sh
    set -e
    [ "$(uname -s)" = Darwin ] || {
        echo "release: run this on the signing Mac — notarization needs the keychain identity" >&2
        exit 64
    }
    version=$(cat VERSION)
    [ "$version" = "{{TAG}}" ] || {
        echo "release: VERSION says $version, not {{TAG}}" >&2
        exit 64
    }
    git diff --quiet HEAD -- VERSION || {
        echo "release: VERSION has uncommitted changes — commit the bump first" >&2
        exit 64
    }
    remote=${EMO_RELEASE_REMOTE:-atom}
    branch=$(git rev-parse --abbrev-ref HEAD)

    if ! git rev-parse -q --verify "{{TAG}}^{tag}" >/dev/null 2>&1; then
        git tag -a "{{TAG}}" -m "Emo {{TAG}}"
        echo "release: cut {{TAG}} at $(git rev-parse --short HEAD)"
    fi
    git push "$remote" "$branch" "{{TAG}}"

    echo "release: building and testing the archives"
    devtools/build-release.sh "{{TAG}}" dist
    echo "release: notarizing the macOS archive"
    just notarize dist
    echo "release: publishing to the download site"
    devtools/publish-release.sh "{{TAG}}" dist
    echo "release: {{TAG}} live at https://www.emo-lang.cn/cdn/dist/{{TAG}}/"

# test: run the full test suite, stopping at the first failure
test:
    dune test --stop-on-first-error

# Run the test suite with Alcotest's per-case output, so a hang points
# at the test case it is stuck in. `--force` reruns suites dune would
# otherwise skip, `--no-buffer` streams a suite's output instead of
# holding it until the suite exits, `-j 1` keeps the suites from
# interleaving, `--stop-on-first-error` stops the remaining suites at
# the first failure, and `script` gives the tests a terminal — Alcotest
# prints the name of the case it is running only when its output is a
# tty. Without `script`, the completed case names still stream.
#
# test-verbose: run the test suite, printing each test case name as it starts
test-verbose:
    #!/bin/sh
    set -e
    export ALCOTEST_VERBOSE=1
    case "$(uname -s)" in
    Darwin)
        script -q /dev/null dune test --force --no-buffer -j 1 --stop-on-first-error --display quiet
        ;;
    *)
        if script --version 2>/dev/null | grep -q util-linux; then
            script -q -e -c "dune test --force --no-buffer -j 1 --stop-on-first-error --display quiet" /dev/null
        else
            dune test --force --no-buffer -j 1 --stop-on-first-error --display quiet
        fi
        ;;
    esac

alias tv := test-verbose

# Every example compiled and run against its golden (opt-in; outside
# `dune test`).
#
# test-bootstrap: run the example bootstrap builds
test-bootstrap:
    dune build @bootstrap

# Every example compiled and run on the typescript target (opt-in;
# outside `dune test`).
#
# test-ts-golden: run the typescript example goldens
test-ts-golden:
    dune build @ts_golden

# The beam-compiling cases, which run erlc (opt-in; outside `dune test`).
#
# test-beam: run the beam-compiling cases
test-beam:
    dune build @beam

# Everything: the @runtest suites, the opt-in example groups, the full
# wasm corpora, and the metal suite.
#
# test-full: run every test suite, including the opt-in gates
test-full:
    EMO_BEAM=1 dune test --stop-on-first-error
    dune build --stop-on-first-error @bootstrap @ts_golden
    dune build --stop-on-first-error @wasm_spec @wasm_runs
    dune build --stop-on-first-error @emo_os

# Every example's golden test, one program at a time: an example under
# examples/ that holds both main.emo and expected.txt runs on the
# interpreter, and its stdout must match the golden file byte for byte.
# A non-zero exit is a failure by itself, and its stderr is printed in
# place. FILTER keeps only examples whose name contains it; the
# per-example stdout and stderr stay in .emo-build/example-golden/ for
# inspection.
#
# The registry is this tree's own packages, staged the way the family
# gates stage them, so resolution never reaches the network; an example
# carrying fixtures/tls-ca.pem runs with SSL_CERT_FILE pointing at it,
# as its header says.
#
# Examples whose golden no interpreter run prints are reported as
# skipped, not failed: the compiled-only ones bind C libraries or
# foreign definitions, and the freestanding ones need the riscv64 image
# or the runtime's own arena notices. Those belong to the compiled
# gates (@bootstrap, @ts_golden, @emo_os).
#
# example: golden-test the examples byte for byte (FILTER, default all)
example FILTER="" CURFEW="300":
    #!/bin/sh
    set -u
    filter="{{FILTER}}"
    curfew="{{CURFEW}}"
    ROOT="{{justfile_directory()}}"
    EMO="$ROOT/_build/default/src/emo_cli/emo.exe"
    OUT="$ROOT/.emo-build/example-golden"
    REG="$ROOT/.emo-build/example-registry"
    dune build src/emo_cli/emo.exe
    "$ROOT/scripts/stage-registry.sh" "$REG"
    export EMO_REGISTRY="$REG"
    mkdir -p "$OUT"
    compiled_only="fastmath_demo fastmath_elefunt numerics postgres_demo quad_demo sqlite3_demo term_demo"
    freestanding="arena_gone survivors native_image parity_metal peek_poke"
    pass=0
    fail=0
    skip=0
    failed=""
    for dir in "$ROOT"/examples/*/; do
      name=$(basename "$dir")
      case "$name" in
      *"$filter"*) ;;
      *) continue ;;
      esac
      if [ ! -f "$dir/main.emo" ] || [ ! -f "$dir/expected.txt" ]; then
        echo "skip  $name (no main.emo or expected.txt)"
        skip=$((skip + 1))
        continue
      fi
      case " $compiled_only " in
      *" $name "*)
        echo "skip  $name (compiled-only)"
        skip=$((skip + 1))
        continue
        ;;
      esac
      case " $freestanding " in
      *" $name "*)
        echo "skip  $name (freestanding golden)"
        skip=$((skip + 1))
        continue
        ;;
      esac
      if [ -f "$dir/fixtures/tls-ca.pem" ]; then
        (cd "$dir" && SSL_CERT_FILE=fixtures/tls-ca.pem "$EMO" run main.emo --no-color --curfew="$curfew" < /dev/null > "$OUT/$name.out" 2> "$OUT/$name.err")
      else
        (cd "$dir" && "$EMO" run main.emo --no-color --curfew="$curfew" < /dev/null > "$OUT/$name.out" 2> "$OUT/$name.err")
      fi
      status=$?
      if [ "$status" -ne 0 ]; then
        echo "FAIL  $name (exit $status)"
        head -5 "$OUT/$name.err" | sed 's/^/      /'
        fail=$((fail + 1))
        failed="$failed $name"
      elif cmp -s "$OUT/$name.out" "$dir/expected.txt"; then
        echo "ok    $name"
        pass=$((pass + 1))
      else
        echo "FAIL  $name (bytes)"
        cmp "$OUT/$name.out" "$dir/expected.txt" 2>&1 | head -1 | sed 's/^/      /'
        fail=$((fail + 1))
        failed="$failed $name"
      fi
    done
    echo
    echo "$pass passed, $fail failed, $skip skipped"
    if [ "$fail" -gt 0 ]; then
      echo "failed:$failed"
      exit 1
    fi

# Re-pin every stale package.lock in the tree — the one command to run
# after a package's sources change. Each tracked lock's directory
# resolves in place through `emo deps resolve`; the family packages the
# bundled library cannot serve (emo/ui*, the fb tree, emo-db's,
# syscall) stage through scripts/stage-registry.sh into a registry
# under .emo-build, because EMO_REGISTRY replaces the bundled library.
# REGISTRY=<dir> resolves everything against one staged registry
# instead of letting the recipe stage one for you.
#
# lock-refresh: re-pin every stale lock in the tree (REGISTRY=<dir> optional)
lock-refresh REGISTRY="":
    #!/bin/sh
    set -e
    ROOT={{justfile_directory()}}
    EMO="$ROOT/_build/default/src/emo_cli/emo.exe"
    [ -x "$EMO" ] || { echo "build the CLI first: just build" >&2; exit 64; }
    # The bundled library the resolver reads is compiled into this
    # binary — a package source edited since the last build would
    # refresh nothing, so rebuild first.
    (cd "$ROOT" && dune build src/emo_cli/emo.exe)
    REG={{REGISTRY}}
    if [ -z "$REG" ]; then
      REG="$ROOT/.emo-build/lock-refresh-registry"
      "$ROOT/scripts/stage-registry.sh" "$REG"
    fi
    export EMO_REGISTRY="$REG"
    status=0
    for lock in $(git -C "$ROOT" ls-files '*package.lock'); do
      dir="$ROOT/$(dirname "$lock")"
      if (cd "$dir" && "$EMO" deps resolve >/dev/null 2>&1); then
        echo "ok   $lock"
      else
        echo "FAIL $lock" >&2
        (cd "$dir" && "$EMO" deps resolve >/dev/null) | head -4 >&2 || true
        status=1
      fi
    done
    # The editors' server registries are generated copies git does not
    # track, so the loop above cannot reach their locks: they are
    # re-pinned here by hand. They resolve against the bundled library
    # — the one the editors' test rules read them through — so the
    # staged REGISTRY does not apply to them.
    for pom in $(find "$ROOT/editors" -name package.emo -path '*/registry/*' \
        -not -path '*/_build/*' -not -path '*/.emo-build/*'); do
      dir=$(dirname "$pom")
      rel="editors/${dir#"$ROOT"/editors/}"
      if (cd "$dir" && env -u EMO_REGISTRY "$EMO" deps resolve >/dev/null 2>&1); then
        echo "ok   $rel"
      else
        echo "FAIL $rel" >&2
        (cd "$dir" && env -u EMO_REGISTRY "$EMO" deps resolve >/dev/null) | head -4 >&2 || true
        status=1
      fi
    done
    exit $status

push:
    git push origin && git push atom

# tour: compile and run every ```emo block of the language tour, then
# check that the two languages carry the same executable payload. Each
# block is its own project built with `emo build --target wasm` and run
# under the compiler's bundled Node host; stdout is compared byte for
# byte with the block's ```output fence.
#
# tour: check the executable language tour
tour:
    dune build src/emo_cli/emo.exe
    devtools/tour-check.sh docs/intro/tour.md docs/zh-CN/intro/tour.md
    devtools/tour-check.sh --pair docs/intro/tour.md docs/zh-CN/intro/tour.md

# tour-selftest: the checker rejects what the grammar forbids — unlabeled
# fences, duplicate ids, a require without a dep, a stray output block,
# wrong stdout, and a program that does not compile.
#
# tour-selftest: check the tour checker's rejection paths
tour-selftest:
    devtools/tour-check-selftest.sh

# tour-site: render docs/intro/tour.md and its Chinese mirror into the static
# site under _build/tour-site (inline CSS, GitHub links for the docs the
# page points at). Needs python3 with the `markdown` package.
#
# tour-site: build the tour as a static HTML site
tour-site:
    python3 devtools/build-tour-site.py

# publish-tour: build and upload the tour site to docs.emo-lang.cn over
# the same SSH channel the release uses (EMO_DOCS_HOST /
# EMO_DOCS_ROOT). The one-time DNS + nginx + certbot setup is in
# devtools/nginx/docs.emo-lang.cn.conf.
#
# publish-tour: upload the tour to docs.emo-lang.cn
publish-tour:
    devtools/publish-tour.sh

# publish-tour-dry: show what publish-tour would upload, touching nothing
publish-tour-dry:
    devtools/publish-tour.sh --dry-run
