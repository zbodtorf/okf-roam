EMACS ?= emacs

.PHONY: test check

test:
	$(EMACS) --batch --quick --eval '(setq load-prefer-newer t)' -L . -L test \
		-l test/okf-roam-test.el \
		-f ert-run-tests-batch-and-exit

check:
	$(EMACS) --batch --quick -L . \
		-f batch-byte-compile okf-roam.el
