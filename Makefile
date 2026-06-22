NAME    = dnf-automatic-reboot
VERSION = 1.1
TARBALL = $(NAME)-$(VERSION).tar.gz

PREFIX      = /usr/local
LIBDIR      = $(PREFIX)/lib/$(NAME)
UNITDIR     = /usr/lib/systemd/system
CONFDIR     = /etc/dnf
DOCDIR      = /usr/share/doc/$(NAME)

SCRIPTS = scripts/run.sh scripts/watchdog.sh scripts/needs-reboot.sh
UNITS   = units/dnf-automatic-reboot.service \
          units/dnf-automatic-reboot.timer \
          units/dnf-automatic-watchdog.service \
          units/dnf-automatic-watchdog.timer \
          units/grub-boot-success.service
CONF    = conf/automatic-reboot.conf
DOC     = doc/README

.PHONY: all install uninstall dist clean

all:
	@echo "Run: make install   (as root)"
	@echo "Run: make dist      (to create source tarball)"

install:
	install -d -m 0755 $(DESTDIR)$(LIBDIR)
	install -d -m 0755 $(DESTDIR)$(UNITDIR)
	install -d -m 0755 $(DESTDIR)$(DOCDIR)
	install -m 0750 $(SCRIPTS) $(DESTDIR)$(LIBDIR)/
	install -m 0644 $(UNITS)   $(DESTDIR)$(UNITDIR)/
	install -m 0640 $(CONF)    $(DESTDIR)$(CONFDIR)/$(NAME).conf
	install -m 0644 $(DOC)     $(DESTDIR)$(DOCDIR)/README

uninstall:
	rm -f  $(DESTDIR)$(LIBDIR)/run.sh
	rm -f  $(DESTDIR)$(LIBDIR)/watchdog.sh
	rm -f  $(DESTDIR)$(LIBDIR)/needs-reboot.sh
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-reboot.service
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-reboot.timer
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-watchdog.service
	rm -f  $(DESTDIR)$(UNITDIR)/dnf-automatic-watchdog.timer
	rm -f  $(DESTDIR)$(UNITDIR)/grub-boot-success.service
	rm -rf $(DESTDIR)$(LIBDIR)
	rm -rf $(DESTDIR)$(DOCDIR)

dist:
	tar czf $(TARBALL) --transform 's,^,$(NAME)-$(VERSION)/,' \
	    Makefile $(SCRIPTS) $(UNITS) $(CONF) $(DOC)
	@echo "Created $(TARBALL)"

clean:
	rm -f $(TARBALL)
