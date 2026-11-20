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

# The base image's opam repository is a local git snapshot opam never
# fetches — update answers "no changes from git+file://..." — and it
# was frozen before 5.5.2 was released, so the switch create below
# finds no compiler until the repository points at the live upstream.
RUN sudo apt-get update && \
    sudo apt-get install -y --no-install-recommends libssl-dev pkg-config && \
    sudo rm -rf /var/lib/apt/lists/* && \
    opam repository set-url default https://opam.ocaml.org && \
    opam update && \
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

# The riscv64 refusal suite's positive control builds with the real
# cross binutils. QEMU stays out — the suite skips the boots the image
# cannot run.
RUN sudo apt-get update && \
    sudo apt-get install -y --no-install-recommends binutils-riscv64-unknown-elf && \
    sudo rm -rf /var/lib/apt/lists/*
