# The emo toolchain's build automation.
#
# The emo CLI itself is OCaml — dune is the one step that needs an
# OCaml toolchain, and everything downstream of it does not: the built
# binary carries the standard library inside it and its default build
# path is the c target, so an installed emo needs only the system cc.

default:
    @just --list

# Build the emo CLI in the release profile — the single binary every
# other recipe installs or packages.
#
# build: compile the release binary
build:
    dune build --profile release src/emo_cli/emo.exe

# Install the release binary into PREFIX (default ~/.local/bin) as a
# symlink to this tree's build output — the dev install: every `dune
# build` here refreshes the installed `emo` immediately, no reinstall.
# The link rides the tree — moving or removing this checkout (or
# `dune clean`) breaks `emo` until the next build here. The binary
# itself is still the standalone c-target build, where `emo build`
# afterwards needs only the system cc. Verify with `emo doctor`.
#
# install: install the release binary as a symlink (PREFIX, default ~/.local/bin)
install PREFIX="$HOME/.local/bin":
    dune build --profile release src/emo_cli/emo.exe
    mkdir -p {{PREFIX}}
    ln -sfn "{{justfile_directory()}}/_build/default/src/emo_cli/emo.exe" "{{PREFIX}}/emo"
    @echo "linked {{PREFIX}}/emo -> _build/default/src/emo_cli/emo.exe — verify with: emo doctor"

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
# uninstall: remove the installed emo link
uninstall PREFIX="$HOME/.local/bin":
    rm -f {{PREFIX}}/emo

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

# test: run the full test suite
test:
    dune test

# Run the test suite with Alcotest's per-case output, so a hang points
# at the test case it is stuck in. `--force` reruns suites dune would
# otherwise skip, `--no-buffer` streams a suite's output instead of
# holding it until the suite exits, `-j 1` keeps the suites from
# interleaving, and `script` gives the tests a terminal — Alcotest
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
        script -q /dev/null dune test --force --no-buffer -j 1 --display quiet
        ;;
    *)
        if script --version 2>/dev/null | grep -q util-linux; then
            script -q -e -c "dune test --force --no-buffer -j 1 --display quiet" /dev/null
        else
            dune test --force --no-buffer -j 1 --display quiet
        fi
        ;;
    esac

alias tv := test-verbose

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
    exit $status

push:
    git push origin && git push atom
