# lightpanda-patched

Nightly builds of [lightpanda-io/browser](https://github.com/lightpanda-io/browser)
with the CDP Mozilla User-Agent restriction removed.

Upstream reserves any user agent containing `mozilla`, so a Mozilla-style user
agent cannot be set through `--user-agent`, `Emulation.setUserAgentOverride`, or
`Network.setExtraHTTPHeaders`. This repository tracks upstream `main`, removes
that one restriction, and publishes the result. See [NOTICE.md](NOTICE.md) for
exactly what changes and what does not.

## Download

The `nightly` tag is a rolling release, so its asset URLs are stable:

```sh
curl -L -o lightpanda \
  https://github.com/Xevion/lightpanda-patched/releases/download/nightly/lightpanda-x86_64-linux
chmod +x lightpanda
```

There are two channels:

| Channel | Tags | Tracks |
| --- | --- | --- |
| Nightly | rolling `nightly`, plus immutable `build-<date>-<sha>` | upstream `main`, daily |
| Released | `<version>-patched`, e.g. `0.3.7-patched` | upstream tagged releases |

Nightly is what this repository is for, so it stays the GitHub "latest" release.
The `<version>-patched` mirrors exist for pinning to a known upstream release;
they are never pruned.

Only upstream releases the patch actually applies to are mirrored. Upstream did
not enforce the user-agent restriction on the CLI until 2026-08-15, so `0.3.7`
is the oldest mirrorable release, and anything earlier is skipped on purpose.

| Platform | Asset | Support |
| --- | --- | --- |
| Linux x86_64 | `lightpanda-x86_64-linux` | required |
| Linux aarch64 | `lightpanda-aarch64-linux` | required |
| macOS aarch64 | `lightpanda-aarch64-macos` | best effort |
| macOS x86_64 | `lightpanda-x86_64-macos` | best effort |

Releases also carry `SHA256SUMS`, build provenance attestation, a
`build-info.json` recording the exact inputs, and the diff the build produced.

`lightpanda version` identifies a patched binary at runtime: nightlies report
`1.0.0-nightly-patched.<count>+<sha>`, mirrors report `0.3.7-patched.<count>+<sha>`.

## How the patch works

The change is not a stored diff. [`tools/patch`](tools/patch) parses each
upstream Zig file with `std.zig.Ast` and edits the matched syntax nodes, so it
survives upstream reformatting and unrelated nearby edits. Every site must
resolve to exactly one node; an anchor that matches nothing, or matches more
than one thing, fails the build rather than being guessed at. Two HTML test
fixtures and the help text are matched as exact substrings, under the same
must-be-unique rule.

It currently covers 25 sites across 9 files: the restriction itself, every
upstream test that asserted it, and the `--help` text that documented it.

Patched output is re-rendered through the same renderer `zig fmt` is built on,
so generated code is formatted by construction.

## Verification

The patch rewrites upstream's own test expectations, so those rewrites are
checked rather than assumed. Every build runs:

- the patch tool's unit tests,
- upstream's full `zig build test` suite against the patched tree,
- an end-to-end check that the published binary sends a Mozilla user agent over
  the wire, and still rejects a non-printable one.

## Local use

```sh
just test                      # the patch tool's own tests
just patch-check               # does the patch still apply to upstream main?
just patch-history 200         # how far back do the anchors match?
just lightpanda-test           # upstream's suite against the patched tree
just lightpanda-build          # release binary, as CI ships it
just serve                     # patched CDP server on 127.0.0.1:9222
```

Every recipe takes an optional upstream ref, e.g. `just patch-check v0.5.0`.

## License

AGPL-3.0, inherited from upstream. See [LICENSE](LICENSE) and
[NOTICE.md](NOTICE.md).
