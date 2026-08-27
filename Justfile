lightpanda_repo := "https://github.com/lightpanda-io/browser.git"
lightpanda_src := "vendor/lightpanda-src"
lightpanda_bin := lightpanda_src / "zig-out/bin/lightpanda"
lightpanda_patch_snapshot := "patches/lightpanda-cdp-user-agent.patch"
patch_tool := "tools/patch/main.zig"

default:
    @just --list

# Run the patch tool's own unit tests.
test:
    zig test tools/patch/patch.zig

# Check our own sources are formatted (CI runs this on every push).
check:
    zig fmt --check tools/

format:
    zig fmt tools/

# Clone (first run) and fast-forward lightpanda-io/browser to REF.
lightpanda-fetch ref="origin/main":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{ lightpanda_src }}/.git" ]; then
        git clone "{{ lightpanda_repo }}" "{{ lightpanda_src }}"
    fi
    git -C "{{ lightpanda_src }}" fetch origin
    # --force so a previous patch run's edits can't block the checkout.
    git -C "{{ lightpanda_src }}" -c advice.detachedHead=false checkout --force "{{ ref }}"

# Reset the checkout and structurally apply the patch.
lightpanda-patch ref="origin/main": (lightpanda-fetch ref)
    # The tool renders its own output, so no separate `zig fmt` pass is needed.
    git -C "{{ lightpanda_src }}" reset --hard
    zig run {{ patch_tool }} -- "{{ lightpanda_src }}"

# Report whether every patch site still matches REF, without writing anything.
patch-check ref="origin/main":
    #!/usr/bin/env bash
    set -euo pipefail
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    for f in $(zig run {{ patch_tool }} -- --targets); do
        mkdir -p "$work/$(dirname "$f")"
        git -C "{{ lightpanda_src }}" show "{{ ref }}:$f" > "$work/$f"
    done
    zig run {{ patch_tool }} -- --check "$work"

# Audit how far back the patch's anchors match, one check per commit, no builds.
patch-history n="200" ref="origin/main":
    #!/usr/bin/env bash
    # Each commit's files are read with `git show`, so the working tree is never
    # touched. All sites vanishing at once dates the commit that introduced the
    # restriction; a single site vanishing alone is real anchor drift.
    set -euo pipefail
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    zig build-exe {{ patch_tool }} -femit-bin="$work/patchtool"
    targets=$("$work/patchtool" --targets)

    printf '%-11s  %-10s  %-8s  %s\n' COMMIT DATE RESULT DETAIL
    boundary=""
    prev_sha=""
    for sha in $(git -C "{{ lightpanda_src }}" rev-list --first-parent -n {{ n }} "{{ ref }}"); do
        short=$(git -C "{{ lightpanda_src }}" rev-parse --short=9 "$sha")
        date=$(git -C "{{ lightpanda_src }}" show -s --format=%cs "$sha")

        tree="$work/tree"
        rm -rf "$tree"
        absent=""
        for f in $targets; do
            mkdir -p "$tree/$(dirname "$f")"
            if ! git -C "{{ lightpanda_src }}" show "$sha:$f" > "$tree/$f"; then
                absent="$f"
                break
            fi
        done
        if [ -n "$absent" ]; then
            printf '%-11s  %-10s  %-8s  %s\n' "$short" "$date" "ABSENT" "$absent does not exist yet"
            [ -z "$boundary" ] && boundary="$prev_sha"
            prev_sha="$short"
            continue
        fi

        out=$("$work/patchtool" --check --json "$tree" || true)
        applied=$(jq -r .applied <<< "$out")
        failed=$(jq -r .failed <<< "$out")
        if [ "$failed" = "0" ]; then
            printf '%-11s  %-10s  %-8s  %s\n' "$short" "$date" "ok" "$applied sites"
        else
            detail=$(jq -r '[.sites[] | select(.status != "applied") | "\(.site) [\(.status)]"] | join("; ")' <<< "$out")
            printf '%-11s  %-10s  %-8s  %s\n' "$short" "$date" "FAIL" "$detail"
            [ -z "$boundary" ] && boundary="$prev_sha"
        fi
        prev_sha="$short"
    done

    echo
    if [ -z "$boundary" ]; then
        echo "every one of the last {{ n }} commits patches cleanly"
    else
        echo "oldest commit that still patches cleanly: $boundary"
    fi

# Regenerate a local (gitignored) copy of the diff, for browsing only.
lightpanda-diff ref="origin/main": (lightpanda-patch ref)
    mkdir -p patches
    git -C "{{ lightpanda_src }}" diff > "{{ lightpanda_patch_snapshot }}"

# Build the patched debug binary (fast iteration).
lightpanda-build-dev ref="origin/main": (lightpanda-patch ref)
    cd {{ lightpanda_src }} && make download-v8 && make build-dev

# Build the patched release binary (matches what CI ships).
lightpanda-build ref="origin/main": (lightpanda-patch ref)
    cd {{ lightpanda_src }} && make download-v8 && make build

# Run upstream's own test suite against the patched tree.
lightpanda-test ref="origin/main": (lightpanda-patch ref)
    # The patch rewrites upstream's expectations; this proves the rewrite holds.
    cd {{ lightpanda_src }} && make download-v8 && make test

# Run the patched CDP server on 127.0.0.1:9222 (debug build).
serve: lightpanda-build-dev
    {{ lightpanda_bin }} serve --port 9222 --log-level info
