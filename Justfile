lightpanda_repo := "https://github.com/lightpanda-io/browser.git"
lightpanda_src := "vendor/lightpanda-src"
lightpanda_bin := lightpanda_src / "zig-out/bin/lightpanda"
lightpanda_patch := "patches/lightpanda-cdp-user-agent.patch"

default:
    @just --list

# Clone (first run) and fast-forward lightpanda-io/browser to the latest main.
lightpanda-fetch:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{lightpanda_src}}/.git" ]; then
        git clone "{{lightpanda_repo}}" "{{lightpanda_src}}"
    fi
    git -C "{{lightpanda_src}}" fetch origin main
    git -C "{{lightpanda_src}}" checkout origin/main

# Check whether the patch still applies cleanly to the current checkout, without modifying it.
lightpanda-check: lightpanda-fetch
    git -C "{{lightpanda_src}}" apply --check "../../{{lightpanda_patch}}"

# Reset the checkout and (re)apply the patch. Safe to re-run.
lightpanda-patch: lightpanda-fetch
    #!/usr/bin/env bash
    set -euo pipefail
    git -C "{{lightpanda_src}}" checkout -- .
    git -C "{{lightpanda_src}}" apply "../../{{lightpanda_patch}}"

# Build the patched debug binary (fast iteration).
lightpanda-build-dev: lightpanda-patch
    cd {{lightpanda_src}} && make download-v8 && make build-dev

# Build the patched release binary (matches what CI ships).
lightpanda-build: lightpanda-patch
    cd {{lightpanda_src}} && make download-v8 && make build

# Run the patched CDP server on 127.0.0.1:9222 (debug build).
serve: lightpanda-build-dev
    {{lightpanda_bin}} serve --port 9222 --log-level info
