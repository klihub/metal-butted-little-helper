# Aggregates the subprojects.  Each owns its own Makefile; this one exists so
# that `make check` from the repo root keeps working as more are added.

SUBPROJECTS := emacs

.PHONY: check compile clean

check compile clean:
	@for d in $(SUBPROJECTS); do \
	  echo "==> $$d: $@"; \
	  $(MAKE) --no-print-directory -C $$d $@ || exit 1; \
	done
