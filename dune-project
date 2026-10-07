(lang dune 3.24)
(name emo)

; The opam package (T25.8) is generated from this stanza — the source
; channel that brings the ocaml compilation target.
(generate_opam_files true)

(package
 (name emo)
 (synopsis "The Emo programming language toolchain")
 (description
   "Emo is a general-purpose programming language: a clean, explicit,
intuitive surface compiled to native executables (C, OCaml),
WebAssembly, TypeScript, the BEAM, and bare-metal RISC-V. This package
is the toolchain — emo run, check, build, install, doctor, publish —
with the standard library carried inside the binary.")
 (depends
  (ocaml (>= 5.5.0))
  dune
  cmdliner
  eio_main
  ssl
  yojson
  digestif
  (alcotest :with-test))
 (authors "David Zhang")
 (maintainers "David Zhang")
 (license MIT)
 (homepage "https://github.com/emo-lang/emo")
 (bug_reports "https://github.com/emo-lang/emo/issues"))
