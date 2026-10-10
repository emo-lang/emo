# Emo and a Zig backend — an assessment

Written 2026-10-10. This is a technical feasibility assessment, not
decided design; project-state claims reflect the repository as of the
date above, and Zig-version claims reflect Zig 0.17.0 (released
2026-10-01).

The question: should Emo grow a code-generation backend that emits Zig
source — a seventh target beside the interpreter, C, OCaml,
TypeScript, wasm, and BEAM?

## The conclusion

**Technically straightforward — mechanically a mirror of the C target
— but not worth building today.** The one thing a Zig backend would
buy that no existing target buys is safe-mode bounds and overflow
checking on generated code: a real but mid-sized development-time
gain. Against it stands a full backend's worth of work plus a
permanent churn tax: Zig breaks language and std APIs in every
release (0.17.0, nine days old at writing, broke both again, including
one silent breakage), 1.0 has no date, and incremental compilation
covers only x86_64-linux behind `--watch`.

Most of the value a Zig *toolchain* offers is available at a tenth of
the cost by running the existing C target under `zig cc` as the
compiler driver — cross-compilation, static musl binaries, Windows
without MSVC. The recommendation: shelve the backend behind explicit
re-evaluation triggers; evaluate `zig cc` on its own small step if
Windows support or static Linux distribution enters the plan.

## What emitting Zig would involve

Repository facts, as of the date above:

- **Backend shape.** Backends share no module signature; each is a
  standalone emitter with a hand-written dispatch arm in `build_file`
  (`src/emo_cli/emo_cli.ml:185-487`). The C target is `emo_c.ml`
  (2,390 lines) emitting two artifacts — `main.c` and `emo_defs.h` —
  with the runtime riding the compiler as embedded data
  (`emo_c_runtime.c`, 2,737 lines, plus a 420-line header, packed
  into a generated data module by a dune rule). A Zig target mirrors
  this one-for-one: `emo_zig.ml` plus a Zig port of the runtime,
  wired up with one dispatch arm, a doctor line, and a cache key.
- **Build driver.** `emo build --target c` invokes the system `cc`
  (`-O2 -std=c11`, emo_cli.ml:323-329), and doctor compiles and runs
  a smoke program before declaring the default target healthy
  (emo_cli.ml:1596-1642). A Zig target adds a `zig` presence check to
  the same machinery.
- **FFI is the smooth part.** Every `foreign def` is already emitted
  as a bare `extern` declaration into `emo_defs.h`
  (emo_c.ml:2261-2281) — the Zig counterpart is a bare
  `extern fn ... callconv(.c)` declaration. This dodges the worst
  Zig-side instability: `@cImport` was deprecated in 0.16 and removed
  in 0.17, and Emo never needs it.
- **Tests.** Three additions: a `zig_goldens` list and runner in
  `test/emo_cli/emo_cli_test.ml` beside `c_goldens` (23 examples
  today), a golden suite in `test/emo_project/emo_project_test.ml`,
  and nothing else — the 32 examples' `expected.txt` files are
  shared. The house tradition that every target reproduces the
  interpreter's output byte-for-byte would extend to a seventh
  implementation.
- **Stdlib surface.** Package manifests gate per target
  (`targets = [...]`); the five native-facing packages (`os`, `net`,
  `file`, `http`, `bufio`) declare `ocaml, c` today and would be
  expected beside `c` — the runtime's 33 `os_*`/`net_*`/`file_*`
  builtins call libc directly and would keep doing so through extern
  declarations.
- **CI.** The release matrix is four platforms (linux x86_64/aarch64,
  macos x86_64/arm64, release.yml:26-32); each would install Zig.

There are no prior Zig plans anywhere in the repository — the only
mentions are naming-precedent citations in `docs/numeric-width.md`.

## Mechanism by mechanism

| Emo mechanism | Zig counterpart | Verdict |
| --- | --- | --- |
| Tagged value model | tagged union (+ tag and bounds checks in safe mode) | smooth |
| Arena that never recycles (product gate) | `std.heap.ArenaAllocator` | a semantic match — explicit allocators and allocate-only arenas are the same idea |
| `foreign` FFI | bare `extern fn` declarations | smooth; mirrors `emo_defs.h`, dodges the removed `@cImport` |
| C→Emo callbacks (the macOS shim is `.m`) | `export fn` with the C calling convention | smooth at the ABI, but zig cannot compile Objective-C — the AppKit path still needs clang, so "one toolchain" does not hold there |
| Exceptions (`Exception` + data `Map`) | Zig error unions carry no payload | friction: exception values must live on the heap; whenever `begin`/`catch` lands (T12.5, unimplemented), whatever mechanism the C runtime picks — most plausibly `setjmp`/`longjmp` — the Zig backend must mirror it |
| `receive` / fiber scheduling (trampoline + receive labels) | nothing off the shelf (async removed in 0.14) | neutral: hand-port the C runtime's machinery, same cost |

## The core dilemma

**A Zig backend that avoids std is C in different braces.** Stability
would come from keeping every runtime service in Emo's own runtime and
calling libc through extern declarations — exactly what the C target
does. What Zig contributes then shrinks to safe-mode bounds and
overflow checks. That is real, and it is the one genuinely new thing
on offer — but it is bounded, because Emo's product gates already
exclude the C bug class that hurts most: the arena never recycles and
no raw pointer crosses into user code, so use-after-free and most
memory corruption are out by construction.

**A Zig backend that leans on std chases the release train.** The
recent record: 0.16 reworked all I/O behind a `std.Io` interface,
removed most of `std.posix`, and de-globalized environment variables
and argv; 0.17 replaced the allocator family (`DebugAllocator` →
`SafeAllocator`), moved `fmt.allocPrint` into `mem.Allocator.print`,
overhauled the build system's API surface, and shipped one silent
breakage (`@bitCast`'s redefinition can change behavior without a
compile error). A generator that consumes std is a twice-a-year
commitment to full golden regression, indefinitely.

Precedent points the same way. The emit-C lineage is decades deep —
Nim, V, Nelua, Vala, Haxe's C++ backend, Cython — and its stability
argument is exactly the one Zig cannot yet make. The emit-Zig lineage
is empty at production scale: Bun, Ghostty, and TigerBeetle are
*written in* Zig; no shipping language generates Zig source. Being
first at any scale means discovering the pitfalls personally.

Two smaller concerns:

1. **Incremental compilation does not cover this use.** As of 0.17 it
   works only on x86_64-linux and only under
   `zig build -fincremental --watch`; a Mach-O linker and a
   self-hosted aarch64 backend are still pending. Everywhere else,
   every rebuild reanalyzes the whole generated module — an awkward
   fit for the generate-big-file, rebuild-often loop.
2. **Positioning noise.** "Compiles to Zig" invites the "Zig DSL"
   reading. This conflicts with nothing — the design philosophy
   governs Emo's own surface, not its substrate, and target
   independence is settled design — but it is an explanation cost the
   C target does not pay.

## The cheaper alternative: zig cc under the existing C target

The runtime is verified strict C11 across gcc and clang — it in fact
already compiled under `zig cc` once, as the reproduction vehicle for
the strict-C11 CI failure — and `zig cc` is a Clang/LLVM 22 frontend
whose stable surface is far wider than Zig's std. Pointing the
existing C target at it buys, without emitting a line of Zig:

- one toolchain covering the whole release matrix, cross-compiling
  from any host;
- fully static musl Linux binaries, strengthening the single-binary
  distribution story;
- Windows without MSVC — the shortest path, should Windows join the
  release matrix (it is absent today);
- optionally, bundling zig with the distribution for a truly
  zero-dependency toolchain — the Bun move — at roughly 50 MB of
  weight. A decision for another day, noted here only so it does not
  get rediscovered.

Cost: one compiler-driver option in the CLI and a doctor line. One
debt to retire along the way: the c cache key does not include the
compiler-driver version (emo_cli.ml:287-293 hashes source, runtime,
cclib, and the emo binary itself) — with a swappable driver, the
driver's version must join the key, or an upgraded zig serves stale
binaries.

## Recommendation

1. **Shelve the Zig backend.** Re-evaluation triggers, written down
   now so the bar is explicit: Zig 1.0, or language stabilization
   complete (84 proposals still open at 0.17); incremental
   compilation beyond x86_64-linux; or a concrete requirement the C
   target cannot meet through zig cc.
2. **Evaluate zig cc as an optional driver for the C target** as its
   own small step, with the cache-key fix included — particularly if
   Windows support or static Linux distribution enters the plan.
3. **riscv64 stays as planned.** Step 22 emits assembly text directly
   and links with GNU as/ld; it does not pass through Zig, and the
   freestanding value model is already designed.

## References

- Zig downloads and version history: <https://ziglang.org/download/>
- Zig 0.17.0 release notes:
  <https://ziglang.org/download/0.17.0/release-notes.html>
- Zig 0.16.0 release notes:
  <https://ziglang.org/download/0.16.0/release-notes.html>
- Zig news (0.17.0 announcement, 2026-10-02): <https://ziglang.org/news/>
