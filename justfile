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

# Install the release binary into PREFIX (default ~/.local/bin): a
# standalone executable, nothing beside it — the c-target install,
# where `emo build` afterwards needs only the system cc. Verify with
# `emo doctor`.
#
# install: install the standalone binary (PREFIX, default ~/.local/bin)
install PREFIX="$HOME/.local/bin":
    dune build --profile release src/emo_cli/emo.exe
    mkdir -p {{PREFIX}}
    cp _build/default/src/emo_cli/emo.exe {{PREFIX}}/emo.incoming
    chmod 755 {{PREFIX}}/emo.incoming
    strip {{PREFIX}}/emo.incoming
    mv {{PREFIX}}/emo.incoming {{PREFIX}}/emo
    @echo "installed {{PREFIX}}/emo — verify with: emo doctor"

# Build and install through the opam switch instead — the source
# install, which also brings the ocaml compilation target.
#
# install-dev: source install through the opam switch
install-dev:
    dune build
    dune install --bindir=$HOME/.local/bin emo

# Remove the standalone install (the install-dev route is uninstalled
# through opam).
#
# uninstall: remove the standalone binary
uninstall PREFIX="$HOME/.local/bin":
    rm -f {{PREFIX}}/emo

# Assemble the distributable release archive for this platform into
# dist/ — the artifact `release.yml` drafts a GitHub Release from.
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

# Notarize a draft release's macOS archives from this machine — the
# local half of the signing story, since CI runners hold no Developer
# ID private key. Signs with the keychain's Developer ID Application
# identity, notarizes, staples, re-uploads, and refreshes SHA256SUMS.
# Needs a notary credential: EMO_NOTARY_PROFILE (see
# devtools/notarize-release.sh), the ASC key trio, or the Apple ID
# quartet.
#
# notarize: notarize a draft release's macOS archives (TAG, e.g. v0.26.7)
notarize TAG:
    #!/bin/sh
    set -e
    if [ -z "$EMO_NOTARY_PROFILE" ] && [ -z "$EMO_NOTARY_KEY" ] && \
      [ -z "$EMO_NOTARY_APPLE_ID" ]; then
        echo "notarize: set EMO_NOTARY_PROFILE (xcrun notarytool store-credentials)," >&2
        echo "the ASC key trio (EMO_NOTARY_KEY/_KEY_ID/_ISSUER), or the Apple ID quartet" >&2
        exit 64
    fi
    devtools/notarize-release.sh {{TAG}}

# test: run the full test suite
test:
    dune test
