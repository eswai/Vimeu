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
TUNE_BIN    := $(REPO_ROOT)/linux/tune/build/vimeu-tune
PREFIX      ?= /usr
DESTDIR     ?=
# Extra fcitx5 flags for linux-dev-run, e.g. FCITX_ARGS="--disable notificationitem".
FCITX_ARGS  ?=

.PHONY: linux-build linux-build-install linux-test linux-dev-run linux-install

linux-build: $(DIC)
	@echo "==> Building libvimeu.so (Swift, release)"
	swift build -c release --product vimeu
	@echo "==> Building the fcitx5 addon"
	cmake -S linux/fcitx5 -B $(FCITX_BUILD) -DCMAKE_BUILD_TYPE=RelWithDebInfo -DVIMEU_DEV_RUNPATH=ON \
		-DCMAKE_INSTALL_PREFIX=$(PREFIX)
	cmake --build $(FCITX_BUILD)
	@echo "==> Building vimeu-tune"
	env -u LD_LIBRARY_PATH linux/tune/bin/build

# Swift unit tests, then a real fcitx5 Instance driving the addon through the
# testfrontend module (user config and dictionary are not touched), then the
# tuning app's tests, offscreen.
linux-test: linux-build
	swift test
	$(FCITX_BUILD)/test/testvimeu
	env -u LD_LIBRARY_PATH linux/tune/bin/test

# Replace the running fcitx5 with one that loads the addon straight from the
# build tree, logging to this terminal (no -d). Add "vimeu" in
# fcitx5-configtool, then try it in real apps. Ctrl+C stops it; start the
# normal one again with `fcitx5 -rd`. LD_LIBRARY_PATH is cleared so a Swift
# toolchain's compatibility libraries do not leak into fcitx5.
linux-dev-run: linux-build
	env -u LD_LIBRARY_PATH VIMEU_DIC=$(DIC) VIMEU_TUNE=$(TUNE_BIN) \
	FCITX_ADDON_DIRS=$(FCITX_BUILD)/lib/fcitx5:/usr/lib/fcitx5 \
	XDG_DATA_DIRS=$(FCITX_BUILD)/share:$${XDG_DATA_DIRS:-/usr/local/share:/usr/share} \
	fcitx5 -r --verbose=vimeu=5 $(FCITX_ARGS)

# Release builds for installing, in their own directories so the development
# builds (and their tests, which load libvimeu.so from the build tree) stay
# as they are: RUNPATH is only $(PREFIX)/lib/vimeu, tests are not built.
FCITX_INSTALL_BUILD := $(REPO_ROOT)/build/fcitx5-install
TUNE_INSTALL_BUILD  := $(REPO_ROOT)/build/tune-install

linux-build-install: linux-build
	cmake -S linux/fcitx5 -B $(FCITX_INSTALL_BUILD) -DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DCMAKE_INSTALL_PREFIX=$(PREFIX) -DVIMEU_DEV_RUNPATH=OFF -DBUILD_TESTING=OFF
	cmake --build $(FCITX_INSTALL_BUILD)
	env -u LD_LIBRARY_PATH VIMEU_TUNE_BUILD=$(TUNE_INSTALL_BUILD) linux/tune/bin/build \
		CONFIG+=vimeu_install VIMEU_CORE_INSTALL_DIR=$(PREFIX)/lib/vimeu

# Copies only; builds nothing, so it is safe under sudo or fakeroot:
#   make linux-build-install && sudo make linux-install
linux-install:
	@test -x $(TUNE_INSTALL_BUILD)/vimeu-tune -a -f $(FCITX_INSTALL_BUILD)/cmake_install.cmake -a -s $(DIC) \
		|| { echo "ERROR: run 'make linux-build-install PREFIX=$(PREFIX)' first"; exit 1; }
	DESTDIR=$(DESTDIR) cmake --install $(FCITX_INSTALL_BUILD) --strip
	strip --strip-unneeded "$(DESTDIR)$(PREFIX)/lib/vimeu/libvimeu.so"
	install -Dm644 $(DIC) "$(DESTDIR)$(PREFIX)/share/vimeu/vimeu.dic"
	install -Dm755 -s $(TUNE_INSTALL_BUILD)/vimeu-tune "$(DESTDIR)$(PREFIX)/bin/vimeu-tune"
	install -Dm644 linux/tune/share/vimeu-tune.desktop "$(DESTDIR)$(PREFIX)/share/applications/vimeu-tune.desktop"
	install -Dm644 linux/tune/share/vimeu-tune.svg "$(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/vimeu-tune.svg"
	install -Dm644 LICENSE "$(DESTDIR)$(PREFIX)/share/licenses/vimeu/LICENSE"
	install -Dm644 THIRD_PARTY_NOTICES.md "$(DESTDIR)$(PREFIX)/share/licenses/vimeu/THIRD_PARTY_NOTICES.md"

# When a systemd user unit supervises fcitx5 (Omarchy: omarchy-fcitx5.service,
# Restart=always plus D-Bus activation), a hand-started fcitx5 is replaced
# within seconds. Instead, point that unit at the build tree with a runtime
# drop-in (under $XDG_RUNTIME_DIR, gone on reboot) and restart it. Logs go to
# `journalctl --user -u $(FCITX_UNIT) -f`. linux-dev-service-off undoes it.
FCITX_UNIT    ?= omarchy-fcitx5.service
FCITX_DROPIN  := $(XDG_RUNTIME_DIR)/systemd/user/$(FCITX_UNIT).d/vimeu-dev.conf

.PHONY: linux-dev-service linux-dev-service-off
linux-dev-service: linux-build
	mkdir -p "$(dir $(FCITX_DROPIN))"
	printf '[Service]\nEnvironment=VIMEU_DIC=%s\nEnvironment=VIMEU_TUNE=%s\nEnvironment=FCITX_ADDON_DIRS=%s:/usr/lib/fcitx5\nEnvironment=XDG_DATA_DIRS=%s:/usr/local/share:/usr/share\n' \
		"$(DIC)" "$(TUNE_BIN)" "$(FCITX_BUILD)/lib/fcitx5" "$(FCITX_BUILD)/share" > "$(FCITX_DROPIN)"
	systemctl --user daemon-reload
	systemctl --user restart $(FCITX_UNIT)

linux-dev-service-off:
	rm -f "$(FCITX_DROPIN)"
	systemctl --user daemon-reload
	systemctl --user restart $(FCITX_UNIT)
