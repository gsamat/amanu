# amanuensis — build, sign, install.
#
# Signing is not cosmetic here. macOS attributes the microphone and Screen &
# System Audio Recording grants to the binary's code signature; SwiftPM only
# ad-hoc signs, which means the identity *is* the hash, so every rebuild looks
# like a brand-new program and macOS asks for permission again (leaving a trail
# of dead amanuensis entries in System Settings). Signing with a real identity gives
# the binary a stable designated requirement, and the grants survive rebuilds.
#
#   make            build + sign
#   make install    also copy to $(PREFIX)/bin
#   make uninstall  remove the binary and the LaunchAgent
#   make identities list available signing identities
#
# Override the defaults if you need to:
#   make install PREFIX=/usr/local SIGN_ID="Developer ID Application: ..."

PREFIX  ?= $(HOME)/.local
BINDIR   = $(PREFIX)/bin
BUILT    = .build/release/amanuensis
INSTALLED = $(BINDIR)/amanuensis

# Prefer Developer ID (distributable, long-lived) over Apple Development
# (fine for a machine-local tool). Falls back to ad-hoc so a clean checkout on
# a machine with no certificates still builds.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build sign install uninstall identities verify clean

all: sign

build:
	swift build -c release

# --identifier pins the signature to the same bundle ID the embedded
# Info.plist and the LaunchAgent label use, so System Settings shows one
# coherent "amanuensis" rather than a path.
#
# --timestamp keeps the signature valid after the certificate expires (Apple
# Development certs last a year). It needs the network, so fall back to an
# untimestamped signature rather than failing the build on a plane.
#
# No --options runtime: the hardened runtime only buys anything if you're
# notarizing for distribution, and it would gate the mic behind an extra
# entitlement for no local benefit.
sign: build
	@echo "signing as: $(SIGN_ID)"
	@codesign --force --sign "$(SIGN_ID)" \
		--identifier me.samat.amanuensis \
		--timestamp $(BUILT) 2>/dev/null \
	|| codesign --force --sign "$(SIGN_ID)" \
		--identifier me.samat.amanuensis \
		--timestamp=none $(BUILT)
	@codesign --verify --strict --verbose=2 $(BUILT)

install: sign
	@mkdir -p $(BINDIR)
	@# Rename rather than copy in place: overwriting a running binary fails
	@# with ETXTBSY, and rename swaps the directory entry atomically so a
	@# live daemon keeps its old inode until it restarts.
	@cp $(BUILT) $(INSTALLED).new
	@mv -f $(INSTALLED).new $(INSTALLED)
	@echo "installed → $(INSTALLED)"
	@command -v amanuensis >/dev/null 2>&1 \
		|| echo "note: $(BINDIR) is not on your PATH"

uninstall:
	-@$(INSTALLED) install --uninstall 2>/dev/null || true
	@rm -f $(INSTALLED)
	@echo "removed $(INSTALLED)"

identities:
	@security find-identity -v -p codesigning

verify:
	@codesign -dvvv $(INSTALLED) 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature|flags'

clean:
	swift package clean
