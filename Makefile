# Building and installing the `container compose` plugin.
#
# A plugin is a directory with a config file and a binary whose name matches the directory:
#
#   $(PREFIX)/libexec/container-plugins/compose/config.toml
#   $(PREFIX)/libexec/container-plugins/compose/bin/compose
#
# That directory is root owned, so installing needs sudo. The container installer wipes it on
# every upgrade (apple/container#1617), so expect to run `sudo make install` again afterwards.

PREFIX ?= /usr/local
PLUGIN := compose
PLUGIN_DIR := $(PREFIX)/libexec/container-plugins/$(PLUGIN)
BIN_PATH := .build/release/$(PLUGIN)
CONFIG := Sources/$(PLUGIN)/config.toml
VERSION_FILE := Sources/$(PLUGIN)/Version.swift
STAMPED_CONFIG := .build/config.toml

# A tag is the release, so the tag is the source of truth for the version. On a tagged commit
# that is the tag; anywhere else `git describe` says how far past the last tag this is and
# whether the tree is dirty, which is what a build that is not a release should report.
# Override with `make build VERSION=...` if you need to.
DEV_VERSION := 0.0.0-dev
VERSION ?= $(shell git describe --tags --dirty 2>/dev/null || echo $(DEV_VERSION))

# Rewrite the one line that carries the version, in place.
define set_version
@sed -e 's/^let composeVersion = .*/let composeVersion = "$(1)"/' \
	$(VERSION_FILE) > $(VERSION_FILE).tmp && mv $(VERSION_FILE).tmp $(VERSION_FILE)
endef

.PHONY: all build test install uninstall clean stamp unstamp version

all: build

version:
	@echo $(VERSION)

# Write the version into the source that reports it. Kept separate from `build` so CI can
# stamp once and then run several targets against the same value.
stamp:
	$(call set_version,$(VERSION))
	@mkdir -p .build
	@sed -e 's/^version = .*/version = "$(VERSION)"/' $(CONFIG) > $(STAMPED_CONFIG)
	@echo "stamped $(VERSION)"

# Put the working copy back. A stamped Version.swift is a build artefact that happens to live
# in the source tree, and leaving it there would commit a version that disagrees with the tag.
# Written literally rather than restored with git, so it works on an untracked file, with
# changes staged, and without git at all.
unstamp:
	$(call set_version,$(DEV_VERSION))

# Stamp, build, and restore the tree whether or not the build succeeded.
build:
	@$(MAKE) stamp
	@swift build -c release --product $(PLUGIN); status=$$?; $(MAKE) unstamp; exit $$status

test:
	swift test

# Deliberately not dependent on `build`. This is the target that needs root, and running the
# compiler as root leaves a build directory the user can no longer write to.
install:
	@test -x "$(BIN_PATH)" || { echo "no $(BIN_PATH); run 'make build' first"; exit 1; }
	@test -f "$(STAMPED_CONFIG)" || { echo "no $(STAMPED_CONFIG); run 'make build' first"; exit 1; }
	install -d "$(PLUGIN_DIR)/bin"
	install -m 0755 "$(BIN_PATH)" "$(PLUGIN_DIR)/bin/$(PLUGIN)"
	install -m 0644 "$(STAMPED_CONFIG)" "$(PLUGIN_DIR)/config.toml"
	@echo "installed to $(PLUGIN_DIR)"
	@echo "run 'container compose --help' to check the CLI has found it"

uninstall:
	rm -rf "$(PLUGIN_DIR)"

clean:
	swift package clean
