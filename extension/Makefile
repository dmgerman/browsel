EXTENSION_NAME ?= chrome-server-extension
VERSION        := $(shell python3 -c 'import json; print(json.load(open("config.json"))["extension"]["version"])')

# ── Directories ──────────────────────────────────────────────────────────────
#
# Everything under extension/ (this directory) is SOURCE.  The Makefile
# materialises a clean, loadable copy in $(BUILD_DIR) — Chrome's
# "Load unpacked" should always point there, never at the source tree.
# The release zip lands in $(DIST_DIR), outside the source tree.

BUILD_DIR        ?= build
DIST_DIR         ?= ../dist
ZIP              := $(DIST_DIR)/$(EXTENSION_NAME)-$(VERSION).zip
BUILD_ABS        := $(abspath $(BUILD_DIR))
MANIFEST_BUILDER := scripts/build-manifest.py

# Sources copied verbatim into $(BUILD_DIR).  manifest.json is generated
# from config.json, so it is NOT listed here — see the build rule.
SRC_FILES := config.json \
             src/background.js \
             src/handlers.js \
             src/payload.js \
             src/consent.js \
             src/offscreen.js \
             src/popup.js \
             src/options.js \
             src/content.js \
             src/content-chatgpt.js \
             html/offscreen.html \
             html/popup.html \
             html/options.html \
             icons/icon16.png \
             icons/icon48.png \
             icons/icon128.png \
             icons/icon-red-16.png \
             icons/icon-red-48.png \
             icons/icon-red-128.png

.PHONY: all build package lint clean load help

all: build

help:
	@echo "Targets:"
	@echo "  make build     — materialise $(BUILD_DIR)/ (load this in Chrome)"
	@echo "  make load      — build, copy $(BUILD_DIR) path to clipboard,"
	@echo "                   open chrome://extensions"
	@echo "  make package   — produce $(ZIP) from $(BUILD_DIR)"
	@echo "  make lint      — validate config.json + check source files exist"
	@echo "  make clean     — remove $(BUILD_DIR)/ and $(DIST_DIR)/"

# ── Source-side checks (no build artefacts) ─────────────────────────────────

lint:
	@echo "validating config.json"
	@python3 -c 'import json; json.load(open("config.json"))' \
	  || { echo "config.json is not valid JSON"; exit 1; }
	@for f in $(SRC_FILES); do \
	  if [ ! -f "$$f" ]; then echo "missing source file: $$f"; exit 1; fi; \
	done
	@echo "checking that every imported JS module is in SRC_FILES"
	@for f in $(filter src/%.js,$(SRC_FILES)); do \
	  for imp in $$(grep -oE 'from[[:space:]]*"\./[^"]+\.js"' "$$f" \
	                  | sed -E 's/.*"\.\/([^"]+)"/src\/\1/'); do \
	    case " $(SRC_FILES) " in \
	      *" $$imp "*) ;; \
	      *) echo "$$f imports $$imp but it is not in SRC_FILES"; exit 1 ;; \
	    esac; \
	  done; \
	done
	@echo "OK"

# ── Build the loadable directory ─────────────────────────────────────────────

# Re-materialise whenever any source file or the manifest builder changes.
$(BUILD_DIR)/manifest.json: lint config.json $(MANIFEST_BUILDER) $(SRC_FILES)
	@rm -rf $(BUILD_DIR)
	@mkdir -p $(BUILD_DIR)
	@echo "copying sources into $(BUILD_DIR)/"
	@for f in $(SRC_FILES); do \
	  mkdir -p "$(BUILD_DIR)/$$(dirname $$f)"; \
	  cp "$$f" "$(BUILD_DIR)/$$f"; \
	done
	@python3 $(MANIFEST_BUILDER) $(BUILD_DIR)/manifest.json
	@python3 -c 'import json; json.load(open("$(BUILD_DIR)/manifest.json"))' \
	  || { echo "generated manifest is not valid JSON"; exit 1; }
	@echo "build OK -> $(BUILD_ABS)"

build: $(BUILD_DIR)/manifest.json

# ── Package and clean ────────────────────────────────────────────────────────

$(DIST_DIR):
	mkdir -p $(DIST_DIR)

package: build $(DIST_DIR)
	@echo "building $(ZIP)"
	@rm -f $(ZIP)
	@cd $(BUILD_DIR) && zip -r -q $(abspath $(ZIP)) .
	@echo "wrote $(ZIP)"

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)

# ── Convenience: load into Chrome ────────────────────────────────────────────
#
# `make load` does three things to make loading the unpacked extension
# fast on macOS:
#   1. build $(BUILD_DIR)/ from current sources
#   2. put the BUILD path on the clipboard so Cmd-V works in the Chrome
#      file picker
#   3. open Chrome on chrome://extensions
# On first run the user still has to: enable Developer mode (top right),
# click "Load unpacked", and paste (Cmd-V) into the file picker.  After
# that, just clicking the extension's reload button picks up edits
# (re-run `make build` first).

load: build
	@echo "load directory: $(BUILD_ABS)"
	@printf "%s" "$(BUILD_ABS)" | pbcopy 2>/dev/null && echo "→ path copied to clipboard" \
	  || echo "(could not copy to clipboard; pbcopy unavailable)"
	@open -a "Google Chrome" "chrome://extensions" \
	  || echo "(could not open Chrome; open chrome://extensions manually)"
	@echo
	@echo "Next steps:"
	@echo "  1. Toggle 'Developer mode' (top right) if not already on."
	@echo "  2. Click 'Load unpacked'."
	@echo "  3. Paste the path (Cmd-V) into the file dialog."
