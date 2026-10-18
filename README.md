# project-ext

Directory-hierarchy project settings for Emacs.

`project-ext` looks up the directory hierarchy for a `.project-ext.el`
marker file, reads it as plain data (never evaluated), and

- registers its directory as a `project.el` root when it contains
  `(:is-project-root t)`;
- provides a validated, whitelisted rust-analyzer configuration for
  `eglot-workspace-configuration`;
- falls back to recognizing Cargo workspace roots as `project.el`
  projects.

See the Commentary section of `project-ext.el` for details.

## Why?

This project exists for two reasons.

**Mixed repositories.**  The built-in `project.el` does not handle
mixed repositories well.  For example, the top level of a git
checkout may be a C project, with one or more Rust crates in
subdirectories.  `project.el` sees only the git root, so project
commands and Eglot/rust-analyzer run against the wrong directory for
the Rust parts.

**Per-project rust-analyzer options.**  Some projects need custom
rust-analyzer settings, such as Cargo features, a separate target
directory, or `clippy` as the check command.  Eglot takes these from
`eglot-workspace-configuration`.  Setting that variable per project
would let a repository hand arbitrary configuration to
rust-analyzer, including options like `overrideCommand` that start
external programs.

In principle, directory-local variables (`.dir-locals.el`) could
cover both cases.  In practice they are a poor fit:

- the variables needed here are not marked as safe, so Emacs asks
  every time whether to apply them.  That is deliberate: variables
  like `eglot-workspace-configuration` or `project-find-functions`
  can lead to arbitrary command execution when set from an untrusted
  `.dir-locals.el`;
- confirming those prompts over and over trains users to accept
  whatever a `.dir-locals.el` asks for, which is insecure, especially
  in repositories you did not write yourself.

For mixed repositories alone, Emacs 29 added
`project-vc-extra-root-markers`, which is marked as safe and can be
set in `.dir-locals.el` without a prompt, e.g. to `("Cargo.toml")`.
It falls short for Rust, though: it picks the *nearest* marker, so
inside a Cargo workspace every member crate becomes its own project
instead of the workspace root.  `project-ext` asks Cargo for the
workspace root (`cargo locate-project`) instead.  And it does not
help with rust-analyzer options at all.

`project-ext` takes a different approach.  The marker file is read as
plain data and never evaluated.  Only a small, fixed set of settings
of a known shape is used, so no confirmation prompt is needed.

## Installation

Requires Emacs 30.1 or later.

```elisp
(use-package project-ext
  :vc (:url "https://github.com/ensc/project-ext")   ; or :load-path
  :config
  (project-ext-mode 1)
  (project-ext-setup-eglot))
```

## Marker file

```elisp
((:is-project-root t)
 (:rust-analyzer (:target-dir :tmpdir)
                 (:features ("foo" "bar"))
                 (:no-default-features t)
                 (:check-command "clippy")))
```

Run `M-x project-ext-clear-cache` after editing a marker file.

Supported settings:

| Marker entry                                     | Accepted values             | rust-analyzer setting                                    |
|--------------------------------------------------|-----------------------------|----------------------------------------------------------|
| `(:is-project-root V)`                           | non-nil                     | – (`project.el` root)                                    |
| `(:target-dir V)` (in `:rust-analyzer`)          | `t`, a string, or `:tmpdir` | `cargo.targetDir` (`:tmpdir` also sets `cargo.extraEnv`) |
| `(:features V)` (in `:rust-analyzer`)            | list of strings             | `cargo.features`                                         |
| `(:no-default-features V)` (in `:rust-analyzer`) | `t`                         | `cargo.noDefaultFeatures`                                |
| `(:check-command V)` (in `:rust-analyzer`)       | `"check"` or `"clippy"`     | `check.command`                                          |

Unknown entries and values of the wrong shape are ignored.

## Development

```sh
make            # byte-compile and run ERT tests
make lint       # checkdoc + package-lint (installed into ./.deps)
```

### Adding a rust-analyzer setting

The marker file comes from untrusted repositories, so every setting
is whitelisted on its own.  To add one:

1. **Check that it is safe.**  The value must not choose a program,
   script or command line to run (no `overrideCommand`,
   `server.path`, `extraArgs`, `runnables.command`, build-script or
   proc-macro server overrides, ...).  A setting that only takes a
   path is fine if rust-analyzer uses that path as data, not as
   something it executes.  If in doubt, leave it out.

2. **Pick the marker key.**  Use a kebab-case keyword
   (`:no-default-features`) for the rust-analyzer name
   (`cargo.noDefaultFeatures`).

3. **Extract and validate it** in the builder for its section:
   `project-ext--build-cargo-config` for `cargo.*`,
   `project-ext--build-check-config` for `check.*`.  For a new
   section, add a `project-ext--build-<section>-config` function and
   call it from `project-ext--build-rust-analyzer-config`.  Look the
   key up with `project-ext--entry`, take the `car` (only the first
   value counts), and accept it only if it passes an explicit check:

   | Shape           | Check                           | Forward as                 |
   |-----------------|---------------------------------|----------------------------|
   | boolean         | `(eq v t)`                      | `t`                        |
   | string          | `stringp`                       | the string                 |
   | list of strings | `(and v (list-of-strings-p v))` | `(vconcat v)` (JSON array) |
   | enumeration     | `(member v '("a" "b"))`         | the string                 |

   Never copy a whole sublist or plist from the marker file through
   unchanged.  Keys in the result are rust-analyzer's camelCase
   names as plist keywords (`:noDefaultFeatures`).  `nil` means "not
   set" and is dropped; if an explicit JSON `false` is needed, send
   `:json-false`.

4. **Add tests** in `test/project-ext-test.el`: one for the valid
   shape(s), and bad shapes in
   `project-ext-test-config-rejects-bad-shapes`.  Use
   `project-ext-test--config`, which stubs out cargo.

5. **Document it** in the table above, and in the Commentary of
   `project-ext.el` if its behaviour is not obvious.

6. Run `make all checkdoc package-lint`.

## License

GPL-3.0-or-later; see `LICENSE`.
