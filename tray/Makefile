# system-optimize-tray: the tray app, its root helper, the GNOME Shell
# extension and the optional tuning agent.
#
#   make test                 unit tests (Qt tests skip without PySide6/PyQt6)
#   make lint                 byte-compile, shell and JS syntax checks
#   make install DESTDIR=...  install everything (the packages use this)
#   make install-tray | install-extension | install-agent   (uninstall-* to remove one)
#   ./install.sh --help        the same for people (and system-optimize's installer)
#   make extension-zip        the extension as a zip for extensions.gnome.org-style installs
#
# The helper always goes to /usr/libexec/system-optimize: the polkit policy
# names that exact path, so PREFIX does not move it.

PREFIX     ?= /usr
BINDIR     ?= $(PREFIX)/bin
DATADIR    ?= $(PREFIX)/share
LIBEXECDIR ?= /usr/libexec/system-optimize
SYSCONFDIR ?= /etc
PKGDATADIR ?= $(DATADIR)/system-optimize-tray
POLKITDIR  ?= /usr/share/polkit-1/actions
UUID       := system-optimize@bradvrudney.github.io
EXTDIR     ?= $(DATADIR)/gnome-shell/extensions/$(UUID)
PYTHON     ?= python3
NODE       ?= node
INSTALL    ?= install
VERSION    := $(shell $(PYTHON) -c 'import sys; sys.path.insert(0, "."); import so_tray; print(so_tray.VERSION)')

.PHONY: all test lint install install-tray install-extension install-agent uninstall uninstall-tray uninstall-extension uninstall-agent extension-zip screenshots clean

all:
	@echo "Nothing to build. Try: make test, make install"

test:
	QT_QPA_PLATFORM=offscreen $(PYTHON) -m unittest discover -s tests
	@if command -v $(NODE) >/dev/null; then $(NODE) --test ../gnome-extension/tests/lib.test.mjs; \
	else echo "node not found: skipping the extension tests"; fi

lint:
	$(PYTHON) -m compileall -q so_tray so_agent bin helper tests tools
	$(PYTHON) -c 'import json; [json.load(open(f)) for f in ("data/credits.json", "../gnome-extension/$(UUID)/metadata.json")]'
	$(PYTHON) -c 'import xml.dom.minidom as m; m.parse("data/io.github.bradvrudney.system-optimize.policy")'
	bash -n install-agent.sh
	bash -n install.sh
	bash -n ../packaging/make-tarball.sh
	@if command -v shellcheck >/dev/null; then shellcheck install-agent.sh install.sh ../packaging/make-tarball.sh; fi
	@if command -v desktop-file-validate >/dev/null; then desktop-file-validate data/*.desktop; fi
	@if command -v $(NODE) >/dev/null; then for f in ../gnome-extension/$(UUID)/*.js; do $(NODE) --check $$f || exit 1; done; fi

install: install-tray install-extension install-agent

install-tray:
	$(INSTALL) -d $(DESTDIR)$(PKGDATADIR)/so_tray $(DESTDIR)$(BINDIR) $(DESTDIR)$(LIBEXECDIR) $(DESTDIR)$(POLKITDIR) \
	    $(DESTDIR)$(DATADIR)/applications $(DESTDIR)$(SYSCONFDIR)/xdg/autostart \
	    $(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps $(DESTDIR)$(DATADIR)/icons/hicolor/symbolic/apps
	$(INSTALL) -m 644 so_tray/*.py $(DESTDIR)$(PKGDATADIR)/so_tray/
	$(INSTALL) -m 644 data/credits.json $(DESTDIR)$(PKGDATADIR)/credits.json
	$(INSTALL) -m 644 data/whats-new.md $(DESTDIR)$(PKGDATADIR)/whats-new.md
	$(INSTALL) -m 755 bin/system-optimize-tray bin/system-optimize-tray-backend $(DESTDIR)$(BINDIR)/
	$(INSTALL) -m 755 helper/system-optimize-helper $(DESTDIR)$(LIBEXECDIR)/system-optimize-helper
	$(INSTALL) -m 644 data/io.github.bradvrudney.system-optimize.policy $(DESTDIR)$(POLKITDIR)/
	$(INSTALL) -m 644 data/io.github.bradvrudney.SystemOptimizeTray.desktop $(DESTDIR)$(DATADIR)/applications/
	$(INSTALL) -m 644 data/system-optimize-tray-autostart.desktop $(DESTDIR)$(SYSCONFDIR)/xdg/autostart/
	$(INSTALL) -m 644 data/icons/system-optimize-tray.svg $(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/
	$(INSTALL) -m 644 data/icons/system-optimize-tray-symbolic.svg $(DESTDIR)$(DATADIR)/icons/hicolor/symbolic/apps/

install-extension:
	$(INSTALL) -d $(DESTDIR)$(EXTDIR)/icons
	$(INSTALL) -m 644 ../gnome-extension/$(UUID)/metadata.json ../gnome-extension/$(UUID)/*.js \
	    ../gnome-extension/$(UUID)/stylesheet.css $(DESTDIR)$(EXTDIR)/
	$(INSTALL) -m 644 ../gnome-extension/$(UUID)/icons/*.svg $(DESTDIR)$(EXTDIR)/icons/

install-agent:
	$(INSTALL) -d $(DESTDIR)$(PKGDATADIR)/so_agent $(DESTDIR)$(BINDIR) $(DESTDIR)$(PKGDATADIR)
	$(INSTALL) -m 644 so_agent/*.py $(DESTDIR)$(PKGDATADIR)/so_agent/
	$(INSTALL) -m 755 bin/system-optimize-agent $(DESTDIR)$(BINDIR)/
	$(INSTALL) -m 755 install-agent.sh $(DESTDIR)$(PKGDATADIR)/install-agent.sh

uninstall: uninstall-tray uninstall-extension uninstall-agent
	-rmdir $(DESTDIR)$(PKGDATADIR) 2>/dev/null

uninstall-tray:
	rm -rf $(DESTDIR)$(PKGDATADIR)/so_tray
	rm -f $(DESTDIR)$(PKGDATADIR)/credits.json $(DESTDIR)$(PKGDATADIR)/whats-new.md \
	    $(DESTDIR)$(BINDIR)/system-optimize-tray $(DESTDIR)$(BINDIR)/system-optimize-tray-backend \
	    $(DESTDIR)$(LIBEXECDIR)/system-optimize-helper \
	    $(DESTDIR)$(POLKITDIR)/io.github.bradvrudney.system-optimize.policy \
	    $(DESTDIR)$(DATADIR)/applications/io.github.bradvrudney.SystemOptimizeTray.desktop \
	    $(DESTDIR)$(SYSCONFDIR)/xdg/autostart/system-optimize-tray-autostart.desktop \
	    $(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/system-optimize-tray.svg \
	    $(DESTDIR)$(DATADIR)/icons/hicolor/symbolic/apps/system-optimize-tray-symbolic.svg

uninstall-extension:
	rm -rf $(DESTDIR)$(EXTDIR)

uninstall-agent:
	rm -rf $(DESTDIR)$(PKGDATADIR)/so_agent
	rm -f $(DESTDIR)$(BINDIR)/system-optimize-agent $(DESTDIR)$(PKGDATADIR)/install-agent.sh

extension-zip:
	mkdir -p dist
	cd ../gnome-extension/$(UUID) && zip -qr ../../tray/dist/$(UUID).shell-extension.zip metadata.json *.js stylesheet.css icons

screenshots:
	QT_QPA_PLATFORM=offscreen $(PYTHON) tools/screenshots.py screenshots-out

clean:
	rm -rf dist screenshots-out
	find . -name __pycache__ -prune -exec rm -rf {} +
