;;; project-ext.el --- Directory-hierarchy project settings  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Enrico Scholz

;; Author:  Enrico Scholz <enrico.scholz@ensc.de>
;; URL: https://github.com/ensc/project-ext
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This module looks up the directory hierarchy for a marker file
;; named `project-ext-file-name' (".project-ext.el" by default),
;; reads it as a single Elisp data form (never evaluated), and
;; exposes a curated subset of its settings to the rest of Emacs.
;;
;; The marker file holds a list of (KEY VALUE...) entries, e.g.:
;;
;;   ((:is-project-root t)
;;    (:rust-analyzer (:target-dir :tmpdir)
;;                     (:features ("foo" "bar"))
;;                     (:no-default-features t)))
;;
;; This alist-of-lists shape (rather than a flat plist) indents
;; correctly under plain `emacs-lisp-mode', since every entry is its
;; own balanced sublist rather than a bare keyword/value pair that
;; the default indenter mistakes for a function call.  Keys may
;; repeat; `project-ext--entries' returns all matches, in order.
;;
;; - When a non-nil `:is-project-root' entry is present, the
;;   directory is registered as a `project.el' root via
;;   `project-find-functions', at the default (high) priority.
;;
;; - A small, explicit whitelist of rust-analyzer settings is
;;   extracted from the `:rust-analyzer' entries and used to build
;;   the value returned for `eglot-workspace-configuration'.  Unlike
;;   a naive pass-through, this module never forwards arbitrary
;;   keys: only scalar/vector values of a fixed, known shape reach
;;   the final configuration.  This specifically excludes any
;;   setting that rust-analyzer or Eglot would use to spawn an
;;   external process with attacker-controlled arguments
;;   (`overrideCommand', `server.path', ...); `read' cannot execute
;;   Elisp, but a forwarded string can still end up as a
;;   shell/process argument several layers downstream.
;;
;; As a lower-priority fallback (depth 90), a Cargo workspace root
;; (as reported by "cargo locate-project") is also recognized as a
;; transient `project.el' project, so plain Rust crates without a
;; ".project-ext.el" marker still get correct root detection; this
;; fallback never contributes any Eglot/rust-analyzer configuration,
;; it only affects `project.el' commands.
;;
;; `:target-dir' additionally accepts the symbol `:tmpdir', which is
;; resolved by running "cargo metadata" and expanding to a
;; subdirectory of Cargo's own build_directory (the effective
;; `build.build-dir', taking environment variables and
;; .cargo/config.toml into account).  The resolved path is applied
;; three ways, since they govern different things:
;;
;; - `cargo.targetDir' -- rust-analyzer's own final-artifact target
;;   dir, keeping it from contending for Cargo.lock with interactive
;;   builds.
;;
;; - `cargo.extraEnv.CARGO_BUILD_BUILD_DIR' -- the actual location of
;;   build-script output (OUT_DIR); `OUT_DIR' is derived from Cargo's
;;   build-dir, not its target-dir, so `targetDir' alone does not
;;   redirect it.  Setting `CARGO_BUILD_BUILD_DIR' for rust-analyzer's
;;   own cargo invocations is what actually isolates its build-script
;;   runs (and thus its reported `OUT_DIR') from other checkouts
;;   sharing the same global, hashed build-dir.
;;
;; - `cargo.extraEnv.CARGO_TARGET_DIR' -- for tools started by
;;   rust-analyzer that do not get an explicit "--target-dir"
;;   argument, so they agree with `cargo.targetDir'.
;;
;; Only plain data is read (via `read', not `eval'), and only
;; recognized fields of recognized shape are ever forwarded to
;; Eglot; anything else in the file is silently ignored, never
;; executed and never passed through verbatim.

;; Usage:
;;
;;   (require 'project-ext)
;;   (project-ext-mode 1)        ; register `project-find-functions'
;;   (project-ext-setup-eglot)   ; optional: rust-analyzer config

;;; Code:

(require 'project)
(require 'seq)

(defvar eglot-workspace-configuration)

(defgroup project-ext nil
  "Directory-hierarchy project settings."
  :group 'tools)

(defcustom project-ext-file-name ".project-ext.el"
  "Name of the marker file searched for up the directory hierarchy."
  :type 'string
  :group 'project-ext)

(defcustom project-ext-tmpdir-subdir "rust-analyzer"
  "Subdirectory name appended to Cargo's build directory for `:tmpdir'."
  :type 'string
  :group 'project-ext)

(defvar project-ext--cache (make-hash-table :test #'equal)
  "Cache mapping a marker file's truename to its parsed content.")

(defvar project-ext--build-dir-cache (make-hash-table :test #'equal)
  "Cache mapping a workspace directory to its resolved Cargo build directory.")

(defun project-ext--read-file (file)
  "Read and return the single Elisp form stored in FILE.
Return nil if FILE cannot be read or does not contain a form.
This only ever calls `read'; the form is data, never `eval'd."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case err
          (read (current-buffer))
        (error
         (message "project-ext: failed to parse %s: %s" file err)
         nil)))))

(defun project-ext--locate (dir)
  "Return (MARKER-FILE . RAW-DATA) for the nearest marker file above DIR.
RAW-DATA is a list of (KEY VALUE...) entries, or nil."
  (let ((found (locate-dominating-file dir project-ext-file-name)))
    (when found
      (let ((file (expand-file-name project-ext-file-name found)))
        ;; the cached value is never nil, so `with-memoization' is safe
        (with-memoization (gethash (file-truename file) project-ext--cache)
          (cons found (project-ext--read-file file)))))))

(defun project-ext--entries (data key)
  "Return the value lists of all (KEY VALUE...) entries in DATA.
DATA is a list of (KEY VALUE...) forms, as read from a marker file.
Returns a list of VALUE lists, one per matching entry, in order; an
entry (:foo 1 2) contributes (1 2).  KEY may appear more than once.
DATA is untrusted: if it is not a proper list, nil is returned, and
entries that are not proper lists are ignored."
  (when (proper-list-p data)
    (mapcar #'cdr (seq-filter (lambda (e)
                                (and (eq (car-safe e) key)
                                     (proper-list-p e)))
                              data))))

(defun project-ext--entry (data key)
  "Return the VALUE list of the first (KEY VALUE...) entry in DATA, or nil."
  (car (project-ext--entries data key)))

(defun project-ext-root (&optional dir)
  "Return the project root directory for DIR, or nil if none found."
  (car (project-ext--locate (or dir default-directory))))

(defun project-ext--call-cargo (&rest args)
  "Run cargo with ARGS, inserting its output into the current buffer.
Return non-nil if cargo exited successfully, and nil if it failed or
could not be started at all (e.g. because it is not installed on the
host of `default-directory')."
  (condition-case nil
      (eql (apply #'process-file "cargo" nil t nil args) 0)
    (file-error nil)))

(defun project-ext-clear-cache ()
  "Clear all cached marker-file and Cargo metadata results.
Call this after editing a marker file so changes take effect."
  (interactive)
  (clrhash project-ext--cache)
  (clrhash project-ext--build-dir-cache))

;;; project.el integration: explicit marker file (high priority)

(defun project-ext-try (dir)
  "`project-find-functions' entry: find a marker-file project for DIR."
  (let* ((hit  (project-ext--locate dir))
         (root (car hit))
         (data (cdr hit)))
    (when (and root (car (project-ext--entry data :is-project-root)))
      (cons 'project-ext root))))

(cl-defmethod project-root ((project (head project-ext)))
  "Return the root directory of the project-ext PROJECT."
  (cdr project))

;;; project.el integration: Cargo workspace fallback (low priority)
;;
;; Recognizes a Cargo workspace root via "cargo locate-project" when
;; no ".project-ext.el" marker claimed the directory first.  This is
;; purely a `project.el' root-detection fallback; it contributes no
;; Eglot/rust-analyzer configuration.

(defun project-ext-try-cargo-workspace (dir)
  "`project-find-functions' entry: find a Cargo workspace root for DIR."
  (when (locate-dominating-file dir "Cargo.toml")
    (let* ((default-directory dir)
           (remote-prefix (or (file-remote-p dir) "")))
      (with-temp-buffer
        (when (project-ext--call-cargo "locate-project" "--workspace"
                                       "--message-format" "plain")
          (let ((manifest (string-trim (buffer-string))))
            (unless (string-empty-p manifest)
              (cons 'transient
                    (concat remote-prefix
                            (file-name-directory manifest))))))))))

;;;###autoload
(define-minor-mode project-ext-mode
  "Global minor mode registering project-ext `project-find-functions'.
When enabled, `project-ext-try' is added at the default depth and
`project-ext-try-cargo-workspace' as a low-priority fallback."
  :global t
  :group 'project-ext
  (if project-ext-mode
      (progn
        (add-hook 'project-find-functions #'project-ext-try)
        (add-hook 'project-find-functions #'project-ext-try-cargo-workspace 90))
    (remove-hook 'project-find-functions #'project-ext-try)
    (remove-hook 'project-find-functions #'project-ext-try-cargo-workspace)))

;;; Cargo build-directory discovery.
;;
;; Runs "cargo metadata" once per workspace directory (cached) and
;; extracts the "build_directory" field described in the Cargo
;; documentation.  Nothing here is derived from marker-file content:
;; DIR comes from `default-directory' / the project root, not from
;; untrusted data, so this is not an injection surface.

(defun project-ext--cargo-metadata-build-dir (dir)
  "Return Cargo's build_directory for the workspace containing DIR.
Return nil if `cargo metadata' fails or reports no build directory
\(e.g. because `build.build-dir' is unset)."
  (let ((key (file-truename dir)))
    (let ((cached (gethash key project-ext--build-dir-cache 'project-ext--missing)))
      (if (not (eq cached 'project-ext--missing))
          cached
        (let ((result
               (let ((default-directory dir))
                 (with-temp-buffer
                   (when (project-ext--call-cargo "metadata"
                                                  "--format-version" "1"
                                                  "--no-deps")
                     (condition-case nil
                         (let* ((json (json-parse-string
                                       (buffer-string)
                                       :object-type 'plist
                                       :null-object nil
                                       :false-object nil))
                                (bdir (plist-get json :build_directory)))
                           (and (stringp bdir) (directory-file-name bdir)))
                       (error nil)))))))
          (puthash key result project-ext--build-dir-cache)
          result)))))

;;; Validated extraction of rust-analyzer settings.
;;
;; Every field below is looked up individually and validated against
;; an explicit predicate before being placed into the result.  There
;; is no generic "copy this subtree over" step, so a marker file
;; cannot introduce a key this code does not know about, and cannot
;; smuggle a value through a field whose shape does not match.

(defun project-ext--resolve-tmpdir (dir)
  "Return an isolated per-project directory below DIR's Cargo build_directory.
Returns nil if the build directory cannot be determined."
  (let ((bdir (project-ext--cargo-metadata-build-dir dir)))
    (and bdir (expand-file-name project-ext-tmpdir-subdir bdir))))

(defun project-ext--build-cargo-config (dir spec)
  "Build the rust-analyzer \"cargo\" config plist from validated SPEC entries.
DIR is the project root, used to resolve `:target-dir' when it is
`:tmpdir'.  SPEC is the list of (KEY VALUE...) entries found under
`:rust-analyzer' in the marker file; only the fixed set of keys
below is consulted, each through its own predicate.

When `:target-dir' is `:tmpdir', the same resolved path is applied
as `cargo.targetDir' (rust-analyzer's own final-artifact dir), as the
`CARGO_BUILD_BUILD_DIR' entry of `cargo.extraEnv' (which actually
governs where build scripts write `OUT_DIR') and as its
`CARGO_TARGET_DIR' entry (for tools without an explicit
\"--target-dir\"); see the Commentary section for why all are needed."
  (let (cargo extra-env)
    (let ((raw (car (project-ext--entry spec :target-dir))))
      (cond
       ((booleanp raw)
        (when raw (setq cargo (plist-put cargo :targetDir raw))))
       ((stringp raw)
        (setq cargo (plist-put cargo :targetDir raw)))
       ((eq raw :tmpdir)
        (let ((resolved (project-ext--resolve-tmpdir dir)))
          (when resolved
            (setq cargo (plist-put cargo :targetDir resolved))
            (setq extra-env (plist-put extra-env :CARGO_BUILD_BUILD_DIR resolved))
            (setq extra-env (plist-put extra-env :CARGO_TARGET_DIR resolved)))))))
    (let ((v (car (project-ext--entry spec :features))))
      (when (and v (list-of-strings-p v))
        (setq cargo (plist-put cargo :features (vconcat v)))))
    (let ((v (car (project-ext--entry spec :no-default-features))))
      (when (and (booleanp v) v)
        (setq cargo (plist-put cargo :noDefaultFeatures v))))
    (when extra-env
      (setq cargo (plist-put cargo :extraEnv extra-env)))
    cargo))

(defun project-ext--build-check-config (spec)
  "Build the rust-analyzer \"check\" config plist from validated SPEC entries.
Deliberately does not support `overrideCommand' or arbitrary
`extraArgs': those settings spawn an external process chosen by the
value, which is exactly the injection surface this module refuses to
expose from an untrusted marker file.  Only a closed set of known
checker names is accepted."
  (let ((v (car (project-ext--entry spec :check-command))))
    (when (member v '("check" "clippy"))
      (list :command v))))

(defun project-ext--build-rust-analyzer-config (dir data)
  "Build a validated rust-analyzer configuration plist from raw DATA.
DIR is the project root.  DATA is the list of (KEY VALUE...) entries
read from the marker file.  Returns nil if DATA has no (or no valid)
`:rust-analyzer' entry.  If `:rust-analyzer' appears more than once,
all occurrences' entries are pooled together before extraction."
  (let* ((specs (apply #'append (project-ext--entries data :rust-analyzer)))
         (cargo (and specs (project-ext--build-cargo-config dir specs)))
         (check (and specs (project-ext--build-check-config specs)))
         result)
    (when cargo (setq result (plist-put result :cargo cargo)))
    (when check (setq result (plist-put result :check check)))
    (when result (list :rust-analyzer result))))

;;; eglot integration

(defun project-ext-eglot-workspace-configuration (server)
  "Build a validated `eglot-workspace-configuration' value.
SERVER is the connected `eglot-lsp-server', unused here but required
by the calling convention Eglot uses for function-valued
`eglot-workspace-configuration'.  Only whitelisted, shape-checked
fields ever reach the returned plist; unrecognized keys or malformed
values in the marker file are ignored rather than forwarded."
  (ignore server)
  (let* ((hit  (project-ext--locate default-directory))
         (root (car hit))
         (data (cdr hit)))
    (when root
      (project-ext--build-rust-analyzer-config root data))))

;;;###autoload
(defun project-ext-setup-eglot ()
  "Install the dynamic `eglot-workspace-configuration' handler."
  (setq-default eglot-workspace-configuration
                #'project-ext-eglot-workspace-configuration))

(provide 'project-ext)
;;; project-ext.el ends here
