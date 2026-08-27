lightpanda_repo := "https://github.com/lightpanda-io/browser.git"
lightpanda_src := "vendor/lightpanda-src"
lightpanda_bin := lightpanda_src / "zig-out/bin/lightpanda"
lightpanda_patch_snapshot := "patches/lightpanda-cdp-user-agent.patch"

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

# Reset the checkout, structurally apply the patch (tools/patch), then reformat.
lightpanda-patch: lightpanda-fetch
    #!/usr/bin/env bash
    set -euo pipefail
    git -C "{{lightpanda_src}}" checkout -- .
    zig run tools/patch/main.zig -- "{{lightpanda_src}}"
    zig fmt "{{lightpanda_src}}/src/Config.zig" "{{lightpanda_src}}/src/cdp/domains/emulation.zig" "{{lightpanda_src}}/src/cdp/domains/network.zig"

# Regenerate a local (gitignored) copy of the diff, for browsing only; not used to apply the patch.
lightpanda-diff: lightpanda-patch
    git -C "{{lightpanda_src}}" diff > "{{lightpanda_patch_snapshot}}"

# Build the patched debug binary (fast iteration).
lightpanda-build-dev: lightpanda-patch
    cd {{lightpanda_src}} && make download-v8 && make build-dev

# Build the patched release binary (matches what CI ships).
lightpanda-build: lightpanda-patch
    cd {{lightpanda_src}} && make download-v8 && make build

# Run the patched CDP server on 127.0.0.1:9222 (debug build).
serve: lightpanda-build-dev
    {{lightpanda_bin}} serve --port 9222 --log-level info
