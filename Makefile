# SPDX-License-Identifier: GPL-3.0-or-later
.POSIX:

SHELL = /bin/dash
CC = cc
VERSION = 0.1.0
DESTDIR =
BINDIR = /usr/bin
ETCDIR = /etc
MANDIR = /usr/share/man
MAN5 = build/pkgfile.5 build/pkgmk.conf.5
MAN8 = build/pkgadd.8 build/pkgrm.8 build/pkginfo.8 build/pkgmk.8 \
    build/rejmerge.8
CPPFLAGS = -D_POSIX_C_SOURCE=200809L -DVERSION=\"$(VERSION)\"
CFLAGS = -std=c23 -O2 -Wall -Wextra -Wpedantic -Wformat=2 \
	-Werror=implicit-function-declaration -fstack-protector-strong \
	-fstack-clash-protection -D_FORTIFY_SOURCE=3
LDFLAGS = -static -Wl,-z,relro,-z,now,-z,noexecstack

all: build/pkgadd build/pkgrm build/pkginfo build/pkgmk \
    build/rejmerge $(MAN5) $(MAN8)

build/pkgadd.8: pkgadd.8.in Makefile
	mkdir -p build
	sed 's/#VERSION#/$(VERSION)/g' pkgadd.8.in > $@

build/pkgrm.8: pkgrm.8.in Makefile
	mkdir -p build
	sed 's/#VERSION#/$(VERSION)/g' pkgrm.8.in > $@

build/pkginfo.8: pkginfo.8.in Makefile
	mkdir -p build
	sed 's/#VERSION#/$(VERSION)/g' pkginfo.8.in > $@

build/pkgmk.8: pkgmk.8.in Makefile
	mkdir -p build
	sed 's/#VERSION#/$(VERSION)/g' pkgmk.8.in > $@

build/rejmerge.8: rejmerge.8.in Makefile
	mkdir -p build
	sed 's/#VERSION#/$(VERSION)/g' rejmerge.8.in > $@

build/pkgfile.5: pkgfile.5.in Makefile
	mkdir -p build
	sed 's/#VERSION#/$(VERSION)/g' pkgfile.5.in > $@

build/pkgmk.conf.5: pkgmk.conf.5.in Makefile
	mkdir -p build
	sed 's/#VERSION#/$(VERSION)/g' pkgmk.conf.5.in > $@

build/main.o: src/main.c src/db.h src/pkgadd.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/main.c -o $@

build/db.o: src/db.c src/db.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/db.c -o $@

build/pkginfo.o: src/pkginfo.c src/db.h src/archive.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/pkginfo.c -o $@

build/archive.o: src/archive.c src/archive.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) $$(pkg-config --cflags libarchive) \
	    -c src/archive.c -o $@

build/fs.o: src/fs.c src/fs.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/fs.c -o $@

build/cancel.o: src/cancel.c src/cancel.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/cancel.c -o $@

build/pkgrm.o: src/pkgrm.c src/db.h src/fs.h src/cancel.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/pkgrm.c -o $@

build/config.o: src/config.c src/config.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/config.c -o $@

build/pkgadd.o: src/pkgadd.c src/pkgadd.h src/db.h src/config.h \
    src/archive.h src/install.h src/fs.h src/cancel.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) $$(pkg-config --cflags libarchive) \
	    -c src/pkgadd.c -o $@

build/install.o: src/install.c src/install.h src/archive.h src/fs.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) $$(pkg-config --cflags libarchive) \
	    -c src/install.c -o $@

build/pkgadd: build/main.o build/db.o build/pkginfo.o build/archive.o \
    build/fs.o build/cancel.o build/pkgrm.o build/config.o build/install.o \
    build/pkgadd.o
	$(CC) $(LDFLAGS) -o $@ build/main.o build/db.o build/pkginfo.o \
	    build/archive.o build/fs.o build/cancel.o build/pkgrm.o \
	    build/config.o build/install.o build/pkgadd.o \
	    $$(pkg-config --static --libs libarchive) -lz -lbz2

build/pkgrm: build/pkgadd
	ln -sf pkgadd $@

build/pkginfo: build/pkgadd
	ln -sf pkgadd $@

build/pkgmk-controller.h: scripts/pkgmk tools/embed-pkgmk.sh Makefile
	mkdir -p build
	dash tools/embed-pkgmk.sh scripts/pkgmk > $@.tmp
	mv $@.tmp $@

build/pkgmk: src/pkgmk.c src/pkgmk-workflow.c src/pkgmk-workflow.h \
    build/pkgmk-controller.h Makefile
	$(CC) $(CPPFLAGS) $(CFLAGS) -iquote build -o $@ src/pkgmk.c \
	    src/pkgmk-workflow.c $(LDFLAGS) \
	    $$(pkg-config --static --libs libcrypto)

build/rejmerge-controller.h: scripts/rejmerge tools/embed-pkgmk.sh Makefile
	mkdir -p build
	dash tools/embed-pkgmk.sh scripts/rejmerge rejmerge_controller > $@.tmp
	mv $@.tmp $@

build/rejmerge: src/rejmerge.c src/rejmerge-workflow.c \
    src/rejmerge-workflow.h build/rejmerge-controller.h Makefile
	$(CC) $(CPPFLAGS) $(CFLAGS) -iquote build -o $@ src/rejmerge.c \
	    src/rejmerge-workflow.c $(LDFLAGS)

install: all
	mkdir -p "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(ETCDIR)"
	cp build/pkgadd build/pkgmk build/rejmerge "$(DESTDIR)$(BINDIR)/"
	chmod 755 "$(DESTDIR)$(BINDIR)/pkgadd" \
	    "$(DESTDIR)$(BINDIR)/pkgmk" "$(DESTDIR)$(BINDIR)/rejmerge"
	ln -sf pkgadd "$(DESTDIR)$(BINDIR)/pkgrm"
	ln -sf pkgadd "$(DESTDIR)$(BINDIR)/pkginfo"
	cp config/pkgadd.conf config/pkgmk.conf config/rejmerge.conf \
	    "$(DESTDIR)$(ETCDIR)/"
	chmod 644 "$(DESTDIR)$(ETCDIR)/pkgadd.conf" \
	    "$(DESTDIR)$(ETCDIR)/pkgmk.conf" "$(DESTDIR)$(ETCDIR)/rejmerge.conf"

	mkdir -p "$(DESTDIR)$(MANDIR)/man5" "$(DESTDIR)$(MANDIR)/man8"
	cp $(MAN5) "$(DESTDIR)$(MANDIR)/man5/"
	cp $(MAN8) "$(DESTDIR)$(MANDIR)/man8/"
	for manual in $(MAN5); do \
	    chmod 644 "$(DESTDIR)$(MANDIR)/man5/$${manual##*/}" || exit; \
	done
	for manual in $(MAN8); do \
	    chmod 644 "$(DESTDIR)$(MANDIR)/man8/$${manual##*/}" || exit; \
	done

test-install: all
	dash tests/distribution-staging-integration.sh "$(VERSION)"

test: all
	dash tests/distribution-staging-integration.sh "$(VERSION)"
	dash tests/manual-version-substitution.sh
	dash tests/cli-common-options.sh ./build
	dash tests/pkginfo-database-queries.sh ./build
	dash tests/pkginfo-database-locks.sh ./build/pkginfo
	dash tests/db-lock-lifetime-api.sh
	dash tests/db-record-removal-api.sh
	dash tests/db-record-insertion-api.sh
	dash tests/fs-scoped-removal-api.sh
	dash tests/fs-scoped-mkdir-api.sh
	dash tests/fs-scoped-hardlink-api.sh
	dash tests/fs-scoped-create-api.sh
	dash tests/fs-scoped-symlink-api.sh
	dash tests/fs-archive-path-api.sh
	dash tests/extraction-path-validation-api.sh
	dash tests/extraction-regular-payload-api.sh
	dash tests/extraction-ordered-stream-api.sh
	dash tests/extraction-preflight-regressions.sh
	dash tests/cancel-signal-state-api.sh
	dash tests/config-rule-parser-api.sh
	dash tests/pkgmk-native-boundary-regressions.sh
	dash tests/pkgmk-callback-state-regressions.sh
	dash tests/pkgmk-build-download-integration.sh
	dash tests/rejmerge-native-boundary-regressions.sh
	dash tests/rejmerge-callback-state-regressions.sh
	dash tests/rejmerge-menu-merge-integration.sh
	dash tests/rejmerge-terminal-signal-regressions.sh

# Differential archive checks require a separately built reference executable.
test-reference: test
	dash tests/pkginfo-query-reference-parity.sh
	dash tests/archive-query-regressions.sh
	dash tests/archive-retained-snapshot-api.sh
	dash tests/archive-command-diagnostics.sh
	dash tests/archive-bzip2-regressions.sh
	dash tests/cli-reference-parity.sh
	dash tests/db-commit-recovery-api.sh
	dash tests/pkgrm-lifecycle-integration.sh
	dash tests/pkgrm-failure-recovery-regressions.sh
	dash tests/package-helper-failure-regressions.sh
	dash tests/pkgrm-lookup-protection-regressions.sh
	dash tests/pkgrm-helper-cancellation-regressions.sh
	dash tests/pkgrm-ldconfig-integration.sh
	dash tests/pkgadd-lifecycle-integration.sh
	dash tests/pkgadd-preflight-protection-regressions.sh
	dash tests/pkgadd-ldconfig-integration.sh

clean:
	rm -f build/main.o build/db.o build/pkginfo.o build/archive.o \
	    build/fs.o build/cancel.o build/pkgrm.o build/config.o build/install.o \
	    build/pkgadd.o build/pkgadd build/pkgrm build/pkginfo \
	    build/pkgmk build/pkgmk-controller.h build/pkgmk-controller.h.tmp \
	    build/rejmerge build/rejmerge-controller.h \
	    build/rejmerge-controller.h.tmp $(MAN5) $(MAN8)
