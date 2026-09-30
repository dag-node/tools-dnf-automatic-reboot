# SPDX-License-Identifier: GPL-2.0-or-later
NAME    = dnf-automatic-reboot
VERSION = 1.4.0
TARBALL = $(NAME)-$(VERSION).tar.gz

# /usr/libexec, not /usr/local/lib: /usr/local is reserved for the local
# administrator and does not carry bin_t in the base SELinux policy.
LIBEXECDIR   = /usr/libexec/$(NAME)
UNITDIR      = /usr/lib/systemd/system
CONFDIR      = /etc/dnf
DOCDIR       = /usr/share/doc/$(NAME)
STATEDIR     = /var/lib/$(NAME)
TMPFILESDIR  = /usr/lib/tmpfiles.d
LOGROTATEDIR = /etc/logrotate.d

SCRIPTS = scripts/run.sh \
          scripts/watchdog.sh \
          scripts/needs-reboot.sh \
          scripts/notify-failure.sh
UNITS   = units/dnf-automatic-reboot.service \
          units/dnf-automatic-reboot.timer \
          units/dnf-automatic-watchdog.service \
          units/dnf-automatic-watchdog.timer \
          units/dnf-automatic-reboot-notify@.service
CONF      = conf/automatic-reboot.conf
TMPFILES  = tmpfiles/$(NAME).conf
LOGROTATE = logrotate/$(NAME)
DOC       = doc/README
LICENSE   = LICENSE

TESTS = tests/run-tests.sh
# Operator diagnostics: linted with the scripts, never installed.
TOOLS = tools/verify-grub-boot-flags.sh \
        tools/verify-el-prerequisites.sh

# rpmbuild output goes to ./rpmbuild, emptied on every build, so exactly one
# build of this version is there to install.  DIST and RPM_RELEASE are optional:
#   make rpm DIST=.el9 RPM_RELEASE=0.12.gitabc1234
RPM_TOPDIR = $(CURDIR)/rpmbuild
RPMBUILD_DEFINES = --define "_topdir $(RPM_TOPDIR)" \
                   --define "_sourcedir $(CURDIR)" --define "_specdir $(CURDIR)" \
                   $(if $(DIST),--define "dist $(DIST)") \
                   $(if $(RPM_RELEASE),--define "rpm_release $(RPM_RELEASE)")

.PHONY: all install uninstall dist rpm clean check lint test

all:
	@echo "Run: make check     (syntax, lint and tests)"
	@echo "Run: make install   (as root)"
	@echo "Run: make dist      (to create source tarball)"
	@echo "Run: make rpm       (to build the RPM into ./rpmbuild)"

# Gate for every change: parse, lint, then run the suite.
check: lint test

lint:
	@for script in $(SCRIPTS) $(TESTS) $(TOOLS); do bash -n $$script || exit 1; echo "syntax OK  $$script"; done
	@if command -v shellcheck >/dev/null 2>&1; then \
	    shellcheck -S warning $(SCRIPTS) $(TOOLS) && echo "shellcheck OK"; \
	else \
	    echo "shellcheck not installed - skipping lint"; \
	fi
	@if LC_ALL=C grep -nP '[^\x00-\x7F]' $(SCRIPTS) $(TOOLS) $(CONF) $(UNITS) $(TMPFILES) $(LOGROTATE); then \
	    echo "ERROR: non-ASCII characters found (scripts and config must be ASCII only)"; exit 1; \
	else \
	    echo "ascii OK"; \
	fi

test:
	@bash $(TESTS)

install:
	install -d -m 0755 $(DESTDIR)$(LIBEXECDIR)
	install -d -m 0755 $(DESTDIR)$(UNITDIR)
	install -d -m 0755 $(DESTDIR)$(CONFDIR)
	install -d -m 0755 $(DESTDIR)$(DOCDIR)
	install -d -m 0755 $(DESTDIR)$(TMPFILESDIR)
	install -d -m 0755 $(DESTDIR)$(LOGROTATEDIR)
	install -d -m 0750 $(DESTDIR)$(STATEDIR)
	install -m 0750 $(SCRIPTS)   $(DESTDIR)$(LIBEXECDIR)/
	install -m 0644 $(UNITS)     $(DESTDIR)$(UNITDIR)/
	install -m 0640 $(CONF)      $(DESTDIR)$(CONFDIR)/automatic-reboot.conf
	install -m 0644 $(TMPFILES)  $(DESTDIR)$(TMPFILESDIR)/$(NAME).conf
	install -m 0644 $(LOGROTATE) $(DESTDIR)$(LOGROTATEDIR)/$(NAME)
	install -m 0644 $(DOC)       $(DESTDIR)$(DOCDIR)/README
	install -m 0644 $(LICENSE)   $(DESTDIR)$(DOCDIR)/LICENSE

uninstall:
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-reboot.service
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-reboot.timer
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-watchdog.service
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-watchdog.timer
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-reboot-notify@.service
	rm -f  $(DESTDIR)$(TMPFILESDIR)/$(NAME).conf
	rm -f  $(DESTDIR)$(LOGROTATEDIR)/$(NAME)
	rm -rf $(DESTDIR)$(LIBEXECDIR)
	rm -rf $(DESTDIR)$(DOCDIR)
	rm -rf $(DESTDIR)$(STATEDIR)

dist: check
	tar czf $(TARBALL) --transform 's,^,$(NAME)-$(VERSION)/,' \
	    Makefile $(SCRIPTS) $(UNITS) $(CONF) $(TMPFILES) $(LOGROTATE) \
	    $(TESTS) $(TOOLS) $(DOC) $(LICENSE) $(NAME).spec
	@echo "Created $(TARBALL)"

rpm: dist
	rm -rf $(RPM_TOPDIR)
	rpmbuild -ba $(NAME).spec $(RPMBUILD_DEFINES)
	@echo "Built:"; ls -1 $(RPM_TOPDIR)/RPMS/noarch/*.rpm

clean:
	rm -f $(TARBALL)
	rm -rf $(RPM_TOPDIR)
