EMACS ?= emacs
TESTS := $(wildcard tests/*-test.el)

.PHONY: check compile clean

check:
	$(EMACS) -Q --batch -L . -L tests \
	  $(patsubst %,-l %,$(TESTS)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile metal-butt*.el

clean:
	rm -f *.elc tests/*.elc
