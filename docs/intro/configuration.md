# Configuration

Emo is its own configuration language: a config file is just an Emo expression, and loading it means evaluating that expression. No separate format to learn — blocks, literals, string interpolation, and method calls are all available to configuration.

Config files are evaluated in a restricted profile:

- **Termination is guaranteed** — evaluation runs under a step budget, and every loop iteration counts against it.
- **Evaluation is hermetic** — the result depends only on the file's content and explicitly declared inputs; no hidden file-system or network access.
- **Side-effect free** — evaluating a config produces data, nothing else.

Because the type checker is built in, configuration schemas are just type declarations checked by the same pass — no second schema language needed.

For interop with the outside world, JSON/YAML/TOML remain supported as exchange formats: the standard library reads and writes them, with Emo as the source of truth and those formats as export products.
