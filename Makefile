EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .

EL     = project-ext.el
ELC    = $(EL:.el=.elc)
TESTS  = test/project-ext-test.el

.PHONY: all compile test checkdoc package-lint lint clean

all: compile test

compile: $(ELC)

%.elc: %.el
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $<

test: compile
	$(BATCH) -L test -l $(TESTS) -f ert-run-tests-batch-and-exit

checkdoc:
	$(BATCH) --eval '(checkdoc-file "$(EL)")' 2>&1 | tee checkdoc.log
	@! grep -q ':[0-9]*: ' checkdoc.log

# package-lint is installed into a project-local directory, never
# into the user's ~/.emacs.d
DEPS_DIR = $(CURDIR)/.deps

package-lint:
	$(BATCH) \
	  --eval "(require 'package)" \
	  --eval "(setq package-user-dir \"$(DEPS_DIR)\")" \
	  --eval "(push '(\"melpa\" . \"https://melpa.org/packages/\") package-archives)" \
	  --eval "(package-initialize)" \
	  --eval "(unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint))" \
	  -l package-lint -f package-lint-batch-and-exit $(EL)

lint: checkdoc package-lint

clean:
	rm -f *.elc test/*.elc checkdoc.log
	rm -rf $(DEPS_DIR)
