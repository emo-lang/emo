# The Linux release builder: Ubuntu 22.04 — the oldest glibc the Linux
# archives support — with an OCaml 5.5 switch and the toolchain's opam
# dependencies preinstalled, so a release build only compiles the
# compiler itself. Built once per architecture, locally:
#
#   just release-image arm64
#   just release-image amd64
#
# (amd64 runs under Rosetta and takes its time; that is a one-time
# cost, and the image is reused by every later release.)
FROM ocaml/opam:ubuntu-22.04

RUN sudo apt-get update && \
    sudo apt-get install -y --no-install-recommends libssl-dev pkg-config && \
    sudo rm -rf /var/lib/apt/lists/* && \
    opam switch create 5.5.2 && \
    opam install -y dune cmdliner alcotest eio_main ssl yojson digestif && \
    opam clean

# The TypeScript and wasm goldens run their output on Node. The
# TypeScript target emits .ts files, which Node only executes natively
# since 23.6 (type stripping) — Ubuntu 22.04's own nodejs is 12, and
# even 20 refuses the extension.
RUN sudo apt-get install -y --no-install-recommends gnupg && \
    curl -fsSL https://deb.nodesource.com/setup_24.x | sudo bash - && \
    sudo apt-get install -y --no-install-recommends nodejs && \
    sudo rm -rf /var/lib/apt/lists/*
