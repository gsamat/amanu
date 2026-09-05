# amanu — build the application.
#
# Signing is not cosmetic here. macOS attributes the microphone and Screen &
# System Audio Recording grants to the code signature, and SwiftPM only ad-hoc
# signs, which means the identity *is* the hash — every rebuild would look like
# a brand-new program and macOS would ask for permission again, leaving a trail
# of dead amanu entries in System Settings. A real identity gives the bundle a
# stable designated requirement, and the grants survive rebuilds.
#
#   make            build + sign Amanu.app
#   make run-app    and launch it through LaunchServices
#   make icon       redraw Resources/Amanu.icns from the feather
#   make identities list available signing identities
#   make verify     show the built app's signature
#   make release    build, notarize and publish a release
#   make release-dry  everything except publishing
#
# Override the signing identity if you need to:
#   make SIGN_ID="Developer ID Application: ..."

# Universal: one binary with an arm64 and an x86_64 slice, so the same release
# runs on Apple Silicon and on the Intel Macs still taking macOS 15. Two
# --arch flags move the product out of .build/release into SwiftPM's Apple
# multi-arch directory, which is why this path is not the obvious one.
BUILT = .build/apple/Products/Release/amanu

# The application bundle. Assembled by hand rather than by an Xcode project:
# the package already builds and tests with SwiftPM, and an .app is a
# directory with a plist in it — a second build system to maintain buys
# nothing here.
APP        = .build/Amanu.app
APP_NAME   = Amanu
VERSION   ?= 0.4.16
# A build number that only ever goes up, and says which commit it was.
BUILD     ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ICON       = Resources/Amanu.icns
DIST       = dist
DMG        = $(DIST)/amanu-v$(VERSION)-macos-universal.dmg

# Sparkle arrives as a binary framework in SwiftPM's artifact cache. There is
# no Xcode "Embed Frameworks" phase here, so `make app` copies it in and signs
# it by hand. Lazily expanded on purpose: the artifact only exists after
# `swift build` has resolved it, which happens inside the recipe below.
#
# The slice named for both architectures is the universal one. Matched exactly
# rather than by prefix: a single-architecture Sparkle would link and sign
# fine here and only fail to launch on the Macs this build exists for.
SPARKLE_FW = $(shell find .build/artifacts/sparkle -type d -name Sparkle.framework \
	-path '*macos-arm64_x86_64*' 2>/dev/null | head -1)

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

.PHONY: all build app icon run-app identities verify clean release release-dry

all: app

build:
	swift build -c release --arch arm64 --arch x86_64

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
	@mkdir -p $(APP)/Contents/Resources/Licenses
	@cp LICENSE $(APP)/Contents/Resources/LICENSE
	@cp THIRD-PARTY-NOTICES.md $(APP)/Contents/Resources/
	@cp .build/checkouts/FluidAudio/LICENSE \
		$(APP)/Contents/Resources/Licenses/FluidAudio-LICENSE
	@cp .build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md \
		$(APP)/Contents/Resources/Licenses/FluidAudio-fastcluster-LICENSE.md
	@cp .build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md \
		$(APP)/Contents/Resources/Licenses/FluidAudio-vbx-LICENSE.md
	@cp .build/checkouts/swift-argument-parser/LICENSE.txt \
		$(APP)/Contents/Resources/Licenses/swift-argument-parser-LICENSE.txt
	@cp .build/checkouts/Sparkle/LICENSE \
		$(APP)/Contents/Resources/Licenses/Sparkle-LICENSE
	@cp .build/checkouts/Sparkle/Vendor/ed25519-sparkle/license.txt \
		$(APP)/Contents/Resources/Licenses/Sparkle-ed25519-LICENSE.txt
	@test -s $(APP)/Contents/Resources/LICENSE \
		&& test -s $(APP)/Contents/Resources/THIRD-PARTY-NOTICES.md \
		&& test "$$(find $(APP)/Contents/Resources/Licenses -type f | wc -l | tr -d ' ')" = 6
	@test -n "$(SPARKLE_FW)" || (echo "Sparkle.framework not found — run swift build first"; exit 1)
	@mkdir -p $(APP)/Contents/Frameworks
	@cp -R "$(SPARKLE_FW)" $(APP)/Contents/Frameworks/
	@# Sparkle's XPC services exist so a sandboxed app can still download and
	@# install; amanu is not sandboxed, so they are two more binaries to sign,
	@# notarize and ship for nothing.
	@rm -rf $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices
	@[ -x $(HOME)/.local/bin/unlock-signing-keychain ] \
		&& $(HOME)/.local/bin/unlock-signing-keychain >/dev/null 2>&1 || true
	@echo "signing app as: $(SIGN_ID)"
	@# Innermost first. codesign seals what it finds, so anything signed after
	@# the app that contains it invalidates the app's own seal — and the failure
	@# shows up as a Gatekeeper rejection on someone else's Mac, not here.
	@for nested in \
		$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate \
		$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app \
		$(APP)/Contents/Frameworks/Sparkle.framework ; do \
		codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp "$$nested" \
			2>/dev/null \
		|| codesign --force --sign "$(SIGN_ID)" --options runtime --timestamp=none "$$nested" ; \
	done
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
	@# A missing slice is invisible until someone on the wrong Mac opens the
	@# disk image, so fail here instead.
	@lipo -archs $(APP)/Contents/MacOS/$(APP_NAME) | grep -q x86_64 \
		&& lipo -archs $(APP)/Contents/MacOS/$(APP_NAME) | grep -q arm64 \
		|| (echo "not universal: $$(lipo -archs $(APP)/Contents/MacOS/$(APP_NAME))"; exit 1)
	@echo "built → $(APP) ($(VERSION) build $(BUILD)) · $$(lipo -archs $(APP)/Contents/MacOS/$(APP_NAME))"

# Launch the way a person would: through LaunchServices, so the app is its own
# responsible process. Running the executable from a terminal instead is the
# one thing that reliably breaks system-audio capture (.issues/rca-002).
run-app: app
	@open $(APP)

identities:
	@security find-identity -v -p codesigning

verify:
	@codesign -dvvv $(APP) 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature|flags'
	@lipo -info $(APP)/Contents/MacOS/$(APP_NAME)

# The whole release, fail-closed: tests, bundle, signature, disk image,
# notarization, a draft GitHub release, the signed appcast, and only then
# anything public. scripts/release.sh says what it needs.
release:
	@scripts/release.sh

release-dry:
	@scripts/release.sh --dry-run

clean:
	swift package clean
