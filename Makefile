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

.PHONY: all build test install uninstall clean

all: build

build:
	swift build -c release --product $(PLUGIN)

test:
	swift test

# Deliberately not dependent on `build`. This is the target that needs root, and running the
# compiler as root leaves a build directory the user can no longer write to.
install:
	@test -x "$(BIN_PATH)" || { echo "no $(BIN_PATH); run 'make build' first"; exit 1; }
	install -d "$(PLUGIN_DIR)/bin"
	install -m 0755 "$(BIN_PATH)" "$(PLUGIN_DIR)/bin/$(PLUGIN)"
	install -m 0644 "$(CONFIG)" "$(PLUGIN_DIR)/config.toml"
	@echo "installed to $(PLUGIN_DIR)"
	@echo "run 'container compose --help' to check the CLI has found it"

uninstall:
	rm -rf "$(PLUGIN_DIR)"

clean:
	swift package clean
