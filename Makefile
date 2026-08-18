# amanu — build, sign, install.
#
# Signing is not cosmetic here. macOS attributes the microphone and Screen &
# System Audio Recording grants to the binary's code signature; SwiftPM only
# ad-hoc signs, which means the identity *is* the hash, so every rebuild looks
# like a brand-new program and macOS asks for permission again (leaving a trail
# of dead amanu entries in System Settings). Signing with a real identity gives
# the binary a stable designated requirement, and the grants survive rebuilds.
#
#   make            build + sign the bare binary
#   make install    also copy to $(PREFIX)/bin
#   make app        assemble and sign Amanu.app
#   make run-app    assemble, sign, and launch it through LaunchServices
#   make uninstall  remove the binary and the LaunchAgent
#   make identities list available signing identities
#
# Override the defaults if you need to:
#   make install PREFIX=/usr/local SIGN_ID="Developer ID Application: ..."

PREFIX  ?= $(HOME)/.local
BINDIR   = $(PREFIX)/bin
BUILT    = .build/release/amanu
INSTALLED = $(BINDIR)/amanu

# The application bundle. Assembled by hand rather than by an Xcode project:
# the package already builds and tests with SwiftPM, and an .app is a
# directory with a plist in it — a second build system to maintain buys
# nothing here.
APP        = .build/Amanu.app
APP_NAME   = Amanu
VERSION   ?= 0.2.0
# A build number that only ever goes up, and says which commit it was.
BUILD     ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ICON       = Resources/Amanu.icns

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

.PHONY: all build sign install app icon run-app uninstall identities verify clean

all: sign

build:
	swift build -c release

# --identifier pins the signature to the same bundle ID the embedded
# Info.plist and the LaunchAgent label use, so System Settings shows one
# coherent "amanu" rather than a path.
#
# --timestamp keeps the signature valid after the certificate expires (Apple
# Development certs last a year). It needs the network, so fall back to an
# untimestamped signature rather than failing the build on a plane.
#
# No --options runtime: the hardened runtime only buys anything if you're
# notarizing for distribution, and it would gate the mic behind an extra
# entitlement for no local benefit.
sign: build
	@# The Developer ID key lives in its own keychain, which is locked after a
	@# reboot. Unlocking here rather than relying on a login item means a
	@# release build works on a machine that just booted — and the failure it
	@# prevents is a confusing one: codesign returns errSecInternalComponent
	@# while find-identity still lists the certificate, because that reads the
	@# certificate and never touches the private key.
	@[ -x $(HOME)/.local/bin/unlock-signing-keychain ] \
		&& $(HOME)/.local/bin/unlock-signing-keychain >/dev/null 2>&1 || true
	@echo "signing as: $(SIGN_ID)"
	@codesign --force --sign "$(SIGN_ID)" \
		--identifier me.samat.amanu \
		--timestamp $(BUILT) 2>/dev/null \
	|| codesign --force --sign "$(SIGN_ID)" \
		--identifier me.samat.amanu \
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
	@command -v amanu >/dev/null 2>&1 \
		|| echo "note: $(BINDIR) is not on your PATH"

# Assemble the bundle, then sign it as one thing. The hardened runtime and
# the entitlements are what notarization will ask for later; the identifier is
# pinned so this app and the bare binary it grew out of are the same program
# as far as TCC is concerned.
# Drawn from the same feather the menu bar uses, so the Dock, the window and
# the status item are one program rather than three.
icon:
	@swift scripts/make-icon.swift $(ICON)

$(ICON):
	@swift scripts/make-icon.swift $(ICON)

app: build $(ICON)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(BUILT) $(APP)/Contents/MacOS/$(APP_NAME)
	@sed -e 's/__SHORT_VERSION__/$(VERSION)/' -e 's/__BUILD_VERSION__/$(BUILD)/' \
		Packaging/Amanu-Info.plist > $(APP)/Contents/Info.plist
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@cp $(ICON) $(APP)/Contents/Resources/Amanu.icns
	@[ -x $(HOME)/.local/bin/unlock-signing-keychain ] \
		&& $(HOME)/.local/bin/unlock-signing-keychain >/dev/null 2>&1 || true
	@echo "signing app as: $(SIGN_ID)"
	@codesign --force --sign "$(SIGN_ID)" \
		--identifier me.samat.amanu \
		--options runtime \
		--entitlements Packaging/Amanu.entitlements \
		--timestamp $(APP) 2>/dev/null \
	|| codesign --force --sign "$(SIGN_ID)" \
		--identifier me.samat.amanu \
		--options runtime \
		--entitlements Packaging/Amanu.entitlements \
		--timestamp=none $(APP)
	@codesign --verify --strict --verbose=2 $(APP)
	@echo "built → $(APP) ($(VERSION) build $(BUILD))"

# Launch the way a person would: through LaunchServices, so the app is its own
# responsible process. Running the executable from a terminal instead is the
# one thing that reliably breaks system-audio capture (.issues/rca-002).
run-app: app
	@open $(APP)

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
