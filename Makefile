# Featherweight. The default target runs the test suite in tests/, which is
# what `tclsh featherweight.tcl debug selftest` does on its own.

TCLSH ?= tclsh

.PHONY: test
test:
	$(TCLSH) featherweight.tcl debug selftest
