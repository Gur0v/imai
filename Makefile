# SPDX-License-Identifier: GPL-3.0-or-later
.POSIX:

SHELL = /bin/dash
CC = cc
VERSION = 0.1.5
DESTDIR =
BINDIR = /usr/bin
ETCDIR = /etc
MANDIR = /usr/share/man
MAN5 = build/pkgfile.5 build/pkgmk.conf.5
MAN8 = build/pkgadd.8 build/pkgrm.8 build/pkginfo.8 build/pkgmk.8 \
    build/rejmerge.8
CPPFLAGS = -iquote src -D_POSIX_C_SOURCE=200809L -DVERSION=\"$(VERSION)\"
CFLAGS = -std=c23 -O2 -Wall -Wextra -Wpedantic -Wformat=2 \
	-Werror=implicit-function-declaration -fstack-protector-strong \
	-fstack-clash-protection -D_FORTIFY_SOURCE=3
LDFLAGS = -static -flto=auto -Wl,-z,relro,-z,now,-z,noexecstack
CRYPTO_CFLAGS =
CRYPTO_LIBS = $$(pkg-config --static --libs libcrypto)

all: build/pkgadd build/pkgrm build/pkginfo build/pkgmk \
    build/rejmerge $(MAN5) $(MAN8)

$(MAN5) $(MAN8): Makefile
	mkdir -p build
	source=$@; sed 's/#VERSION#/$(VERSION)/g' "$${source#build/}.in" > $@

build/pkgadd.8: pkgadd.8.in
build/pkgrm.8: pkgrm.8.in
build/pkginfo.8: pkginfo.8.in
build/pkgmk.8: pkgmk.8.in
build/rejmerge.8: rejmerge.8.in
build/pkgfile.5: pkgfile.5.in
build/pkgmk.conf.5: pkgmk.conf.5.in

build/main.o: src/main.c src/db/db.h src/commands/pkgadd/pkgadd.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/main.c -o $@

build/db.o: src/db/db.c src/db/db.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/db/db.c -o $@

build/pkginfo.o: src/commands/pkginfo/pkginfo.c src/db/db.h src/archive/archive.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/commands/pkginfo/pkginfo.c -o $@

build/archive.o: src/archive/archive.c src/archive/archive.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) $$(pkg-config --cflags libarchive) \
	    -c src/archive/archive.c -o $@

build/fs.o: src/fs/fs.c src/fs/fs.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/fs/fs.c -o $@

build/cancel.o: src/cancel/cancel.c src/cancel/cancel.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/cancel/cancel.c -o $@

build/pkgrm.o: src/commands/ldconfig.h src/commands/pkgrm/pkgrm.c src/db/db.h src/fs/fs.h src/cancel/cancel.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/commands/pkgrm/pkgrm.c -o $@

build/ldconfig.o: src/commands/ldconfig.c src/commands/ldconfig.h \
    src/cancel/cancel.h src/fs/fs.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/commands/ldconfig.c -o $@

build/config.o: src/config/config.c src/config/config.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c src/config/config.c -o $@

build/pkgadd.o: src/commands/ldconfig.h src/commands/pkgadd/pkgadd.c src/commands/pkgadd/pkgadd.h src/db/db.h src/config/config.h \
    src/archive/archive.h src/extraction/install.h src/fs/fs.h src/cancel/cancel.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) $$(pkg-config --cflags libarchive) \
	    -c src/commands/pkgadd/pkgadd.c -o $@

build/install.o: src/extraction/install.c src/extraction/install.h src/archive/archive.h src/fs/fs.h Makefile
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) $$(pkg-config --cflags libarchive) \
	    -c src/extraction/install.c -o $@

build/pkgadd: build/ldconfig.o build/main.o build/db.o build/pkginfo.o build/archive.o \
    build/fs.o build/cancel.o build/pkgrm.o build/config.o build/install.o \
    build/pkgadd.o
	$(CC) $(LDFLAGS) -o $@ build/ldconfig.o build/main.o build/db.o build/pkginfo.o \
	    build/archive.o build/fs.o build/cancel.o build/pkgrm.o \
	    build/config.o build/install.o build/pkgadd.o \
	    $$(pkg-config --static --libs libarchive) -lz -lbz2

build/pkgrm: build/pkgadd
	ln -sf pkgadd $@

build/pkginfo: build/pkgadd
	ln -sf pkgadd $@

build/pkgmk-controller.h: src/commands/pkgmk/controller.sh tools/embed-controller.sh Makefile
	mkdir -p build
	dash tools/embed-controller.sh src/commands/pkgmk/controller.sh > $@.tmp
	mv $@.tmp $@

build/pkgmk: src/commands/pkgmk/pkgmk.c src/commands/pkgmk/pkgmk-workflow.c src/commands/pkgmk/pkgmk-workflow.h \
    build/pkgmk-controller.h Makefile
	$(CC) $(CPPFLAGS) $(CFLAGS) $(CRYPTO_CFLAGS) -iquote build \
	    -o $@ src/commands/pkgmk/pkgmk.c src/commands/pkgmk/pkgmk-workflow.c $(LDFLAGS) $(CRYPTO_LIBS)

build/rejmerge-controller.h: src/commands/rejmerge/controller.sh tools/embed-controller.sh Makefile
	mkdir -p build
	dash tools/embed-controller.sh src/commands/rejmerge/controller.sh rejmerge_controller > $@.tmp
	mv $@.tmp $@

build/rejmerge: src/commands/rejmerge/rejmerge.c src/commands/rejmerge/rejmerge-workflow.c \
    src/commands/rejmerge/rejmerge-workflow.h build/rejmerge-controller.h Makefile
	$(CC) $(CPPFLAGS) $(CFLAGS) -iquote build -o $@ src/commands/rejmerge/rejmerge.c \
	    src/commands/rejmerge/rejmerge-workflow.c $(LDFLAGS)

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
	dash tests/distribution/staging-integration.sh "$(VERSION)"

test-distribution: all
	dash tests/distribution/staging-integration.sh "$(VERSION)"
	dash tests/distribution/manual-version-substitution.sh

test-cli: all
	dash tests/cli/common-options.sh ./build

test-cli-reference: all
	dash tests/cli/reference-parity.sh

test-pkginfo: all
	dash tests/pkginfo/database-queries.sh ./build
	dash tests/pkginfo/database-locks.sh ./build/pkginfo

test-pkginfo-reference: all
	dash tests/pkginfo/query-reference-parity.sh

test-db: all
	dash tests/db/lock-lifetime-api.sh
	dash tests/db/record-removal-api.sh
	dash tests/db/record-insertion-api.sh

test-db-reference: all
	dash tests/db/commit-recovery-api.sh

test-fs: all
	dash tests/fs/scoped-removal-api.sh
	dash tests/fs/scoped-mkdir-api.sh
	dash tests/fs/scoped-hardlink-api.sh
	dash tests/fs/scoped-create-api.sh
	dash tests/fs/scoped-symlink-api.sh
	dash tests/fs/archive-path-api.sh

test-extraction: all
	dash tests/extraction/path-validation-api.sh
	dash tests/extraction/regular-payload-api.sh
	dash tests/extraction/ordered-stream-api.sh
	dash tests/extraction/preflight-regressions.sh

test-cancel: all
	dash tests/cancel/signal-state-api.sh

test-config: all
	dash tests/config/rule-parser-api.sh

test-pkgmk: all
	dash tests/pkgmk/native-boundary-regressions.sh
	dash tests/pkgmk/callback-state-regressions.sh
	dash tests/pkgmk/recipe-observation.sh
	dash tests/pkgmk/managed-tmpfs.sh
	dash tests/pkgmk/work-release.sh
	dash tests/pkgmk/download-cancellation.sh
	dash tests/pkgmk/build-download-integration.sh

test-rejmerge: all
	dash tests/rejmerge/native-boundary-regressions.sh
	dash tests/rejmerge/callback-state-regressions.sh
	dash tests/rejmerge/menu-merge-integration.sh
	dash tests/rejmerge/terminal-signal-regressions.sh

test-archive: all
	dash tests/archive/query-regressions.sh
	dash tests/archive/retained-snapshot-api.sh
	dash tests/archive/command-diagnostics.sh
	dash tests/archive/bzip2-regressions.sh

test-pkgrm: all
	dash tests/pkgrm/lifecycle-integration.sh
	dash tests/pkgrm/failure-recovery-regressions.sh
	dash tests/pkgrm/lookup-protection-regressions.sh
	dash tests/pkgrm/helper-cancellation-regressions.sh
	dash tests/pkgrm/ldconfig-integration.sh

test-helpers: all
	dash tests/helpers/failure-regressions.sh

test-pkgadd: all
	dash tests/pkgadd/lifecycle-integration.sh
	dash tests/pkgadd/preflight-protection-regressions.sh
	dash tests/pkgadd/ldconfig-integration.sh

test: test-distribution test-cli test-pkginfo test-db test-fs test-extraction test-cancel test-config test-pkgmk test-rejmerge

test-reference: test test-cli-reference test-pkginfo-reference test-db-reference test-archive test-pkgrm test-helpers test-pkgadd

clean:
	rm -f build/ldconfig.o build/main.o build/db.o build/pkginfo.o build/archive.o \
	    build/fs.o build/cancel.o build/pkgrm.o build/config.o build/install.o \
	    build/pkgadd.o build/pkgadd build/pkgrm build/pkginfo \
	    build/pkgmk build/pkgmk-controller.h build/pkgmk-controller.h.tmp \
	    build/rejmerge build/rejmerge-controller.h \
	    build/rejmerge-controller.h.tmp $(MAN5) $(MAN8)
