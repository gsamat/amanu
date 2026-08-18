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
#
# Override the signing identity if you need to:
#   make SIGN_ID="Developer ID Application: ..."

BUILT = .build/release/amanu

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

.PHONY: all build app icon run-app identities verify clean

all: app

build:
	swift build -c release

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

identities:
	@security find-identity -v -p codesigning

verify:
	@codesign -dvvv $(APP) 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Signature|flags'

clean:
	swift package clean
