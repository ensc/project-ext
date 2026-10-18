# AGENTS.md

Guidance for AI coding agents working on this repository.

## Project

`project-ext` is a single-file Emacs package (`project-ext.el`) that:

- reads a `.project-ext.el` marker file found up the directory tree;
- registers `project.el` roots for mixed repositories (e.g. a C
  project at the git root with Rust crates in subdirectories);
- builds a validated rust-analyzer `eglot-workspace-configuration`.

See `README.md` for the motivation and the Commentary section of
`project-ext.el` for the detailed design.

## Layout

- `project-ext.el` – the package
- `test/project-ext-test.el` – ERT tests
- `Makefile` – build, test and lint targets
- `.forgejo/workflows/ci.yml` – Forgejo Actions CI (Emacs 30.1, 30.2,
  master)

## Commands

```sh
make            # byte-compile (warnings are errors) and run ERT tests
make checkdoc   # docstring checks
make lint       # checkdoc + package-lint
make clean
```

`make package-lint` installs `package-lint` into `./.deps`.  Never
run package commands that install into the user's `~/.emacs.d`.
`emacs -Q` does not isolate `package-user-dir`, so set it explicitly.

All of `make all checkdoc package-lint` must pass before a change is
done.

## Security model (do not weaken)

The marker file is untrusted input; it may come from any cloned
repository.

- Only ever `read` it, never `eval`, `load` or otherwise execute it.
- Never pass marker-file content through generically.  Each
  supported key is looked up individually and checked against an
  explicit predicate or closed set of values; unknown keys and
  malformed values are silently dropped.
- Never support settings that make rust-analyzer, Eglot or Cargo
  spawn a process chosen by the value (`overrideCommand`,
  `server.path`, arbitrary `extraArgs`, ...).
- When adding a new whitelisted setting, follow "Adding a
  rust-analyzer setting" in `README.md`, including tests both for
  the valid shape and for rejected bad shapes.

## Conventions

- Minimum Emacs version is 30.1 (`Package-Requires`).  Don't use
  newer APIs without raising it.
- Loading the package must not change Emacs behaviour.  Hooks are
  installed only through `project-ext-mode`, and the Eglot handler
  only through `project-ext-setup-eglot`.
- Don't `require` eglot at load time; declare variables with
  `defvar` instead.
- Public symbols use the `project-ext-` prefix, internal ones
  `project-ext--`.
- Tests must not need a real `cargo`.  Use the
  `project-ext-test--with-cargo` macro, which stubs `process-file`,
  and `project-ext-test--with-tree` for temporary directory trees.
- Be not woke; use the terms "whitelist" and "blacklist", not "allow-list",
  "deny-list" or similar replacements.
- Match the existing style: `lexical-binding`, checkdoc-clean
  docstrings, comment density similar to the surrounding code.
