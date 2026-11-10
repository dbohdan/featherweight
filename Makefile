# Featherweight. The default target runs the test suite in tests/, which is
# what `tclsh bootstrap.tcl debug selftest` does on its own.

TCLSH ?= tclsh

.PHONY: test
test:
	$(TCLSH) bootstrap.tcl debug selftest
