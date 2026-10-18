;;; project-ext-test.el --- Tests for project-ext  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; ERT tests for project-ext.  External "cargo" invocations are
;; replaced by a stub around `process-file', so cargo is not needed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'project-ext)

(defmacro project-ext-test--with-tree (spec &rest body)
  "Create a temporary directory tree from SPEC and run BODY in it.
SPEC is a list of (RELATIVE-PATH . CONTENT) pairs; a CONTENT of nil
creates a directory.  `root' is bound to the tree's root directory
\(with trailing slash).  Caches are cleared before and after BODY."
  (declare (indent 1) (debug t))
  `(let ((root (file-name-as-directory
                (file-truename (make-temp-file "project-ext-test" t)))))
     (unwind-protect
         (progn
           (dolist (e ,spec)
             (let ((path (expand-file-name (car e) root)))
               (if (cdr e)
                   (progn
                     (make-directory (file-name-directory path) t)
                     (with-temp-file path (insert (cdr e))))
                 (make-directory path t))))
           (project-ext-clear-cache)
           ,@body)
       (project-ext-clear-cache)
       (delete-directory root t))))

(defmacro project-ext-test--with-cargo (handler &rest body)
  "Run BODY with `process-file' calls to \"cargo\" routed to HANDLER.
HANDLER is called with the cargo argument list in the current
buffer (the output destination) and returns the exit status.
Each call is recorded in `cargo-calls' as (DEFAULT-DIRECTORY . ARGS)."
  (declare (indent 1) (debug t))
  `(let ((cargo-calls nil)
         (orig (symbol-function 'process-file)))
     (cl-letf (((symbol-function 'process-file)
                (lambda (program &optional infile buffer display &rest args)
                  (if (equal program "cargo")
                      (progn
                        (push (cons default-directory args) cargo-calls)
                        (funcall ,handler args))
                    (apply orig program infile buffer display args)))))
       ,@body)))

;;; Parsing and lookup

(ert-deftest project-ext-test-entries ()
  (let ((data '((:a 1) (:b 2 3) (:a 4) junk (:c))))
    (should (equal (project-ext--entries data :a) '((1) (4))))
    (should (equal (project-ext--entry data :b) '(2 3)))
    (should (equal (project-ext--entry data :c) nil))
    (should (equal (project-ext--entries data :missing) nil))))

(ert-deftest project-ext-test-entries-malformed ()
  (dolist (data (list 42 t "x" '(a . b) '((:a 1) . b)
                      (let ((l (list '(:a 1)))) (setcdr l l) l)))
    (should-not (project-ext--entries data :a)))
  (should (equal (project-ext--entries '((:a . 1) (:a 1 . 2) (:a 3)) :a)
                 '((3)))))

(ert-deftest project-ext-test-try-malformed ()
  (dolist (content '("42" "t" "(:is-project-root . t)"
                     "((:is-project-root . t))"
                     "((:rust-analyzer . 5))"
                     "((:rust-analyzer (:features . \"a\")) . x)"))
    (project-ext-test--with-tree (list (cons ".project-ext.el" content))
      (should-not (project-ext-try root))
      (let ((default-directory root))
        (should-not (project-ext-eglot-workspace-configuration nil))))))

(ert-deftest project-ext-test-read-file-is-not-evaluated ()
  (project-ext-test--with-tree
      '((".project-ext.el" . "((:x (setq project-ext-test--evil t)))"))
    (defvar project-ext-test--evil nil)
    (let ((data (project-ext--read-file
                 (expand-file-name ".project-ext.el" root))))
      (should (equal data '((:x (setq project-ext-test--evil t)))))
      (should-not project-ext-test--evil))))

(ert-deftest project-ext-test-read-file-malformed ()
  (project-ext-test--with-tree '((".project-ext.el" . "((:x 1)"))
    (let ((inhibit-message t))
      (should-not (project-ext--read-file
                   (expand-file-name ".project-ext.el" root))))))

(ert-deftest project-ext-test-read-file-missing ()
  (should-not (project-ext--read-file "/nonexistent/project-ext/file")))

(ert-deftest project-ext-test-locate-and-root ()
  (project-ext-test--with-tree
      '((".project-ext.el" . "((:is-project-root t))")
        ("a/b/c/"))
    (let ((sub (expand-file-name "a/b/c/" root)))
      (should (equal (project-ext-root sub) root))
      (should (equal (project-ext--locate sub)
                     (cons root '((:is-project-root t))))))))

(ert-deftest project-ext-test-locate-none ()
  (project-ext-test--with-tree '(("a/"))
    (let ((project-ext-file-name ".project-ext-test-nonexistent.el"))
      (should-not (project-ext-root (expand-file-name "a/" root))))))

(ert-deftest project-ext-test-cache-and-clear ()
  (project-ext-test--with-tree '((".project-ext.el" . "((:v 1))"))
    (let ((file (expand-file-name ".project-ext.el" root)))
      (should (equal (cdr (project-ext--locate root)) '((:v 1))))
      (with-temp-file file (insert "((:v 2))"))
      (should (equal (cdr (project-ext--locate root)) '((:v 1))))
      (project-ext-clear-cache)
      (should (equal (cdr (project-ext--locate root)) '((:v 2)))))))

;;; project.el integration

(ert-deftest project-ext-test-try-project-root ()
  (project-ext-test--with-tree
      '((".project-ext.el" . "((:is-project-root t))") ("sub/"))
    (let ((pr (project-ext-try (expand-file-name "sub/" root))))
      (should (equal pr (cons 'project-ext root)))
      (should (equal (project-root pr) root)))))

(ert-deftest project-ext-test-try-not-root ()
  (project-ext-test--with-tree
      '((".project-ext.el" . "((:is-project-root nil) (:rust-analyzer))"))
    (should-not (project-ext-try root))))

(ert-deftest project-ext-test-project-current ()
  (project-ext-test--with-tree
      '((".project-ext.el" . "((:is-project-root t))") ("x/y/"))
    (let ((project-find-functions (list #'project-ext-try)))
      (should (equal (project-root
                      (project-current nil (expand-file-name "x/y/" root)))
                     root)))))

(ert-deftest project-ext-test-mode-hooks ()
  (let ((project-find-functions nil)
        (project-ext-mode nil))
    (project-ext-mode 1)
    (should (memq #'project-ext-try project-find-functions))
    (should (memq #'project-ext-try-cargo-workspace project-find-functions))
    (should (eq (car (last project-find-functions))
                #'project-ext-try-cargo-workspace))
    (project-ext-mode -1)
    (should-not project-find-functions)))

(ert-deftest project-ext-test-cargo-workspace ()
  (project-ext-test--with-tree '(("Cargo.toml" . "[workspace]\n") ("crate/src/"))
    (project-ext-test--with-cargo
        (lambda (args)
          (should (equal args '("locate-project" "--workspace"
                                "--message-format" "plain")))
          (insert (expand-file-name "Cargo.toml" root) "\n")
          0)
      (should (equal (project-ext-try-cargo-workspace
                      (expand-file-name "crate/src/" root))
                     (cons 'transient root))))))

(ert-deftest project-ext-test-cargo-workspace-failure ()
  (project-ext-test--with-tree '(("Cargo.toml" . "[package]\n"))
    (project-ext-test--with-cargo (lambda (_args) 101)
      (should-not (project-ext-try-cargo-workspace root)))))

(defun project-ext-test--cargo-missing (_args)
  "Stub handler behaving like `process-file' for a missing program."
  (signal 'file-missing '("Searching for program" "No such file" "cargo")))

(ert-deftest project-ext-test-cargo-workspace-cargo-missing ()
  (project-ext-test--with-tree '(("Cargo.toml" . "[package]\n"))
    (project-ext-test--with-cargo #'project-ext-test--cargo-missing
      (should-not (project-ext-try-cargo-workspace root)))))

(ert-deftest project-ext-test-cargo-workspace-no-manifest ()
  (project-ext-test--with-tree '(("a/"))
    (project-ext-test--with-cargo
        (lambda (_args) (error "Cargo must not be called"))
      (should-not (project-ext-try-cargo-workspace
                   (expand-file-name "a/" root)))
      (should-not cargo-calls))))

;;; Cargo build directory

(ert-deftest project-ext-test-build-dir ()
  (project-ext-test--with-tree '(("Cargo.toml" . "[package]\n"))
    (project-ext-test--with-cargo
        (lambda (args)
          (should (equal args '("metadata" "--format-version" "1" "--no-deps")))
          (insert "{\"build_directory\": \"/var/cache/build/\", \"x\": null}")
          0)
      (should (equal (project-ext--cargo-metadata-build-dir root)
                     "/var/cache/build"))
      ;; cached: second lookup does not run cargo again
      (should (equal (project-ext--cargo-metadata-build-dir root)
                     "/var/cache/build"))
      (should (= (length cargo-calls) 1)))))

(ert-deftest project-ext-test-build-dir-failures ()
  (dolist (handler (list (lambda (_args) 101)
                         (lambda (_args) (insert "not json") 0)
                         (lambda (_args) (insert "{\"build_directory\": null}") 0)
                         (lambda (_args) (insert "{}") 0)
                         #'project-ext-test--cargo-missing))
    (project-ext-test--with-tree '(("Cargo.toml" . "[package]\n"))
      (project-ext-test--with-cargo handler
        (should-not (project-ext--cargo-metadata-build-dir root))
        (should-not (project-ext--resolve-tmpdir root))))))

;;; rust-analyzer configuration

(defun project-ext-test--config (data)
  "Build the rust-analyzer config for DATA with cargo unavailable."
  (project-ext-test--with-cargo (lambda (_args) 101)
    (project-ext--build-rust-analyzer-config "/nonexistent/" data)))

(ert-deftest project-ext-test-config-empty ()
  (should-not (project-ext-test--config nil))
  (should-not (project-ext-test--config '((:is-project-root t))))
  (should-not (project-ext-test--config '((:rust-analyzer))))
  (should-not (project-ext-test--config '((:rust-analyzer (:unknown "x"))))))

(ert-deftest project-ext-test-config-cargo ()
  (should (equal (project-ext-test--config
                  '((:rust-analyzer (:target-dir "/tmp/t")
                                    (:features ("a" "b"))
                                    (:no-default-features t))))
                 '(:rust-analyzer
                   (:cargo (:targetDir "/tmp/t"
                            :features ["a" "b"]
                            :noDefaultFeatures t))))))

(ert-deftest project-ext-test-config-target-dir-bool ()
  (should (equal (project-ext-test--config '((:rust-analyzer (:target-dir t))))
                 '(:rust-analyzer (:cargo (:targetDir t)))))
  (should-not (project-ext-test--config '((:rust-analyzer (:target-dir nil))))))

(ert-deftest project-ext-test-config-rejects-bad-shapes ()
  (should-not (project-ext-test--config
               '((:rust-analyzer (:target-dir 42)
                                 (:target-dir-other "x")
                                 (:features ("a" 1))
                                 (:features-2 "a")
                                 (:no-default-features "yes")
                                 (:check-command "rm -rf /")
                                 (:overrideCommand ("sh" "-c" "evil")))))))

(ert-deftest project-ext-test-config-features-not-list ()
  (should-not (project-ext-test--config '((:rust-analyzer (:features "a"))))))

(ert-deftest project-ext-test-config-check-command ()
  (should (equal (project-ext-test--config
                  '((:rust-analyzer (:check-command "clippy"))))
                 '(:rust-analyzer (:check (:command "clippy")))))
  (should (equal (project-ext-test--config
                  '((:rust-analyzer (:check-command "check"))))
                 '(:rust-analyzer (:check (:command "check"))))))

(ert-deftest project-ext-test-config-pooled-and-first-wins ()
  (should (equal (project-ext-test--config
                  '((:rust-analyzer (:features ("a")))
                    (:rust-analyzer (:features ("b"))
                                    (:check-command "clippy"))))
                 '(:rust-analyzer
                   (:cargo (:features ["a"])
                    :check (:command "clippy"))))))

(ert-deftest project-ext-test-config-tmpdir ()
  (project-ext-test--with-cargo
      (lambda (_args) (insert "{\"build_directory\": \"/b\"}") 0)
    (let* ((cfg (project-ext--build-rust-analyzer-config
                 temporary-file-directory
                 '((:rust-analyzer (:target-dir :tmpdir)))))
           (cargo (plist-get (plist-get cfg :rust-analyzer) :cargo))
           (env (plist-get cargo :extraEnv))
           (expected (expand-file-name project-ext-tmpdir-subdir "/b")))
      (should (equal (plist-get cargo :targetDir) expected))
      (should (equal (plist-get env :CARGO_BUILD_BUILD_DIR) expected))
      (should (equal (plist-get env :CARGO_TARGET_DIR) expected))))
  (project-ext-clear-cache))

(ert-deftest project-ext-test-config-tmpdir-unresolved ()
  (should-not (project-ext-test--config
               '((:rust-analyzer (:target-dir :tmpdir))))))

(ert-deftest project-ext-test-config-json-serializable ()
  (let ((cfg (project-ext-test--config
              '((:rust-analyzer (:target-dir "/t") (:features ("a"))
                                (:check-command "clippy"))))))
    (should (equal (json-parse-string (json-serialize cfg) :object-type 'plist)
                   '(:rust-analyzer (:cargo (:targetDir "/t" :features ["a"])
                                     :check (:command "clippy")))))))

;;; eglot integration

(ert-deftest project-ext-test-eglot-workspace-configuration ()
  (project-ext-test--with-tree
      '((".project-ext.el" . "((:rust-analyzer (:check-command \"clippy\")))")
        ("src/"))
    (let ((default-directory (expand-file-name "src/" root)))
      (should (equal (project-ext-eglot-workspace-configuration nil)
                     '(:rust-analyzer (:check (:command "clippy"))))))))

(ert-deftest project-ext-test-eglot-workspace-configuration-none ()
  (project-ext-test--with-tree '(("src/"))
    (let ((default-directory (expand-file-name "src/" root))
          (project-ext-file-name ".project-ext-test-nonexistent.el"))
      (should-not (project-ext-eglot-workspace-configuration nil)))))

(ert-deftest project-ext-test-setup-eglot ()
  (let ((eglot-workspace-configuration nil))
    (project-ext-setup-eglot)
    (should (eq (default-value 'eglot-workspace-configuration)
                #'project-ext-eglot-workspace-configuration))))

(provide 'project-ext-test)
;;; project-ext-test.el ends here
