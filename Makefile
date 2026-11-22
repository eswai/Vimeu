# ── Configuration ─────────────────────────────────────────────────────────────
APP_NAME     := VimeuIME
SWIFT_CONFIG := release

REPO_ROOT := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
DICT_DIR  := $(REPO_ROOT)/dict
RES_DIR   := $(REPO_ROOT)/Resources

APP_BUNDLE := $(REPO_ROOT)/$(APP_NAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
MACOS_BIN  := $(CONTENTS)/MacOS
RESOURCES  := $(CONTENTS)/Resources

SWIFT_BIN := $(shell swift build -c $(SWIFT_CONFIG) --show-bin-path 2>/dev/null)

INSTALL_DIR := $(HOME)/Library/Input Methods
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app

# App Sandbox is on by default (2026 input-method guidelines). To debug without
# it: make install ENTITLEMENTS=
ENTITLEMENTS := $(RES_DIR)/Vimeu.entitlements
CODESIGN_FLAGS := --force --sign - $(if $(ENTITLEMENTS),--entitlements $(ENTITLEMENTS),)

# The dictionary is built straight from a copy of Mozc's own src/data — there is
# no intermediate format. Point this at a Mozc checkout to skip the copy:
#   make dict MOZC_DATA=/path/to/mozc/src/data
MOZC_DATA := $(DICT_DIR)/mozc
DIC       := $(DICT_DIR)/vimeu.dic

.PHONY: all build build-swift dict verify-dict assemble sign verify-bundle install test clean

all: build

build: build-swift $(DIC) assemble sign

build-swift:
	@echo "==> Building $(APP_NAME) (Swift, $(SWIFT_CONFIG))"
	swift build -c $(SWIFT_CONFIG)

test:
	swift test

# ── Dictionary ────────────────────────────────────────────────────────────────
# One stage: Mozc's src/data goes in, vimeu.dic comes out. Word costs and POS
# ids are used unchanged, so an intermediate format would be a slower copy of
# Mozc's own files — see DESIGN.md §2.1.
dict: $(DIC)

$(DIC): $(MOZC_DATA)/dictionary_oss/id.def
	@echo "==> Packing $(DIC) from $(MOZC_DATA)"
	swift run -c $(SWIFT_CONFIG) vimeu-dictbuild pack \
		--mozc-data $(MOZC_DATA) --out $(DIC)

$(MOZC_DATA)/dictionary_oss/id.def:
	@echo "ERROR: $(MOZC_DATA) is not Mozc's src/data."
	@echo "       Copy it in:   cp -R /path/to/mozc/src/data $(MOZC_DATA)"
	@echo "       Or point at a checkout:   make dict MOZC_DATA=/path/to/mozc/src/data"
	@exit 1

# Prove the packed dictionary still matches the Mozc data it came from: every
# POS name and boundary penalty, plus a spread of connection cells and word
# tokens. This is the mechanical form of "vimeu uses Mozc's dictionary as-is".
verify-dict: $(DIC)
	swift run -c $(SWIFT_CONFIG) vimeu-dictbuild verify \
		--dic $(DIC) --mozc-data $(MOZC_DATA)

# ── Bundle ────────────────────────────────────────────────────────────────────
assemble:
	@echo "==> Assembling $(APP_BUNDLE)"
	mkdir -p $(MACOS_BIN) $(RESOURCES)/dict
	cp $(SWIFT_BIN)/$(APP_NAME) $(MACOS_BIN)/$(APP_NAME)
	# The dictionary is optional here so the IME shell can be assembled and
	# installed before the dictionary exists; `verify-bundle` still demands it.
	@test -f $(DIC) && cp $(DIC) $(RESOURCES)/dict/ \
	  || echo "    (no dictionary yet — conversion will fall back to kana)"
	# Resources/ is the source of truth for bundle metadata; without these copies
	# edits to Info.plist would silently never reach the built app.
	cp $(RES_DIR)/Info.plist        $(CONTENTS)/Info.plist
	cp $(RES_DIR)/PkgInfo           $(CONTENTS)/PkgInfo
	cp $(RES_DIR)/InfoPlist.strings $(RES_DIR)/MenuIcon.tiff $(RES_DIR)/AppIcon.icns $(RESOURCES)/
	cp $(REPO_ROOT)/LICENSE $(REPO_ROOT)/THIRD_PARTY_NOTICES.md $(RESOURCES)/

sign:
	@echo "==> Signing $(APP_BUNDLE)$(if $(ENTITLEMENTS), (sandboxed),)"
	codesign $(CODESIGN_FLAGS) $(APP_BUNDLE)

# An incomplete bundle installs and launches fine but fails silently at runtime:
# a missing dictionary only shows up as "conversion does nothing", because kana
# input is handled locally and needs no dictionary. Fail loudly instead.
verify-bundle:
	@echo "==> Verifying $(APP_BUNDLE)"
	@for f in $(MACOS_BIN)/$(APP_NAME) $(RESOURCES)/dict/vimeu.dic $(CONTENTS)/Info.plist \
	          $(RESOURCES)/LICENSE $(RESOURCES)/THIRD_PARTY_NOTICES.md; do \
		test -s "$$f" || { echo "ERROR: missing from bundle: $$f"; exit 1; }; \
	done
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :InputMethodConnectionName' $(CONTENTS)/Info.plist)" \
	      = "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $(CONTENTS)/Info.plist)_Connection" \
	  || { echo "ERROR: InputMethodConnectionName must be <bundle id>_Connection"; exit 1; }
	@codesign --verify --verbose=1 $(APP_BUNDLE)
	@echo "    bundle OK"

# ── Install ───────────────────────────────────────────────────────────────────
install: build verify-bundle
	@echo "==> Installing to $(INSTALL_DIR)"
	pkill -x $(APP_NAME) 2>/dev/null || true
	sleep 0.5
	rm -rf "$(INSTALLED)"
	cp -R $(APP_BUNDLE) "$(INSTALLED)"
	codesign $(CODESIGN_FLAGS) "$(INSTALLED)"
	/usr/bin/open "$(INSTALLED)"
	@echo "==> Done. Toggle the input source in System Settings if needed."

clean:
	rm -rf .build $(APP_BUNDLE)
	rm -f $(DIC)

# ── Linux (fcitx5) ────────────────────────────────────────────────────────────
# DESIGN.md §8. libvimeu.so (Swift core + C API) is loaded by the fcitx5 addon
# built from linux/fcitx5. The macOS targets above are not used on Linux.
FCITX_BUILD := $(REPO_ROOT)/build/fcitx5
PREFIX      ?= /usr
DESTDIR     ?=

.PHONY: linux-build linux-test linux-dev-run linux-install

linux-build: $(DIC)
	@echo "==> Building libvimeu.so (Swift, release)"
	swift build -c release --product vimeu
	@echo "==> Building the fcitx5 addon"
	cmake -S linux/fcitx5 -B $(FCITX_BUILD) -DCMAKE_BUILD_TYPE=RelWithDebInfo -DVIMEU_DEV_RUNPATH=ON \
		-DCMAKE_INSTALL_PREFIX=$(PREFIX)
	cmake --build $(FCITX_BUILD)

# Swift unit tests, then a real fcitx5 Instance driving the addon through the
# testfrontend module (user config and dictionary are not touched).
linux-test: linux-build
	swift test
	$(FCITX_BUILD)/test/testvimeu

# Replace the running fcitx5 with one that loads the addon straight from the
# build tree. Add "vimeu" in fcitx5-configtool, then try it in real apps.
linux-dev-run: linux-build
	VIMEU_DIC=$(DIC) \
	FCITX_ADDON_DIRS=$(FCITX_BUILD)/lib/fcitx5:/usr/lib/fcitx5 \
	XDG_DATA_DIRS=$(FCITX_BUILD)/share:$${XDG_DATA_DIRS:-/usr/local/share:/usr/share} \
	fcitx5 -rd

linux-install: linux-build
	cmake -S linux/fcitx5 -B $(FCITX_BUILD) -DVIMEU_DEV_RUNPATH=OFF
	cmake --build $(FCITX_BUILD)
	DESTDIR=$(DESTDIR) cmake --install $(FCITX_BUILD) --strip
	strip --strip-unneeded "$(DESTDIR)$(PREFIX)/lib/vimeu/libvimeu.so"
	install -Dm644 $(DIC) "$(DESTDIR)$(PREFIX)/share/vimeu/vimeu.dic"
	install -Dm644 LICENSE "$(DESTDIR)$(PREFIX)/share/licenses/vimeu/LICENSE"
	install -Dm644 THIRD_PARTY_NOTICES.md "$(DESTDIR)$(PREFIX)/share/licenses/vimeu/THIRD_PARTY_NOTICES.md"
