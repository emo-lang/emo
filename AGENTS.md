# AGENTS.md

## Design Philosophy

- **Zero Rust associations.** Rust is considered an ugly language, and Emo's design philosophy is deliberately the opposite of Rust's. Never propose or accept syntax, keywords, or terminology that resembles Rust — e.g. `mut`, `impl`, `trait`, positional variant payloads like `Rect(String, i32)`, `=>` match arms, lifetimes. Rust's mechanisms are not borrowed either; when surveying prior art, prefer the Ruby / Swift / Kotlin / Elixir lineage.
- **Go: mechanisms may be borrowed, the look never.** Go's good ideas can be absorbed (structural interfaces, the `internal/` directory, Minimal Version Selection, build-as-install), but its known failures are off the table (iota-style enums, receiver syntax), and no naming or surface form may suggest that Emo copied Go — never `go.mod`-style file names or Go-shaped tooling. For a new language, looking like a clone is serious positioning damage.
- Emo's identity is **clean, explicit, and intuitive** — everything is visibly what it is, and every rule follows the principle of least surprise.
- **Strictness first.** Compiler checking defaults to the strict side: surface human mistakes as early as possible. Never trade strictness for convenience — no auto-fixing, no implicit additions, no silent fallbacks.
- **The README contains decided design only.** Never write "not decided yet" placeholders or undecided plans into the README; undecided topics stay out of the document until they are settled.

## Language Policy

This project uses **English only** as its working language:

- All code, identifiers, comments, commit messages, PR descriptions, and documentation must be written in English.
- English is the source of truth for all documentation. Do not mix other languages into English documents.
- Chinese translations of documentation live in `docs/zh-CN/` and nowhere else. When a document is translated, keep the file structure under `docs/zh-CN/` mirroring the English docs.
- When updating an English document, update or flag the corresponding Chinese translation under `docs/zh-CN/` so translations do not silently drift out of date.
