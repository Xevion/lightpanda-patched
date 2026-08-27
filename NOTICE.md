# Notice of modification

This repository builds and distributes **modified** binaries of
[lightpanda-io/browser](https://github.com/lightpanda-io/browser), which is
licensed under the GNU Affero General Public License v3.0. A copy of that
license is in [LICENSE](LICENSE), and it governs the binaries published here.

## What is modified

Upstream refuses any user agent containing the substring `mozilla`, reserving
it so Lightpanda traffic stays self-identifying. This repository removes that
one restriction, so a Mozilla-style user agent can be set through:

- the `--user-agent` command line flag,
- CDP `Emulation.setUserAgentOverride`,
- CDP `Network.setExtraHTTPHeaders` with a `User-Agent` header.

Nothing else is changed. The rest of the user agent validation is untouched:
non-printable characters are still rejected, and the header-smuggling checks in
`Network.setExtraHTTPHeaders` still reject header names that are not valid HTTP
tokens and values carrying CR, LF or NUL.

## Where the modification lives

The change is not stored as a patch file. It is produced by
[`tools/patch`](tools/patch), which parses each upstream file with
`std.zig.Ast` and edits the matched syntax nodes, so it survives upstream
reformatting and nearby edits. That directory is the corresponding source of
the modification, and it is licensed under AGPL-3.0 along with the rest.

Every published release also attaches `lightpanda-cdp-user-agent.patch`, the
unified diff that the run actually produced against that upstream commit, so
the modification can be read without running anything.

## Reproducing a published binary

Each release attaches `build-info.json` recording the exact upstream commit,
the commit of the patch tool used, and the Zig and V8 versions. To rebuild:

```sh
just lightpanda-build <upstream-sha>
```

The published binaries report a `nightly-patched` pre-release tag from
`lightpanda version`, so they are distinguishable from official builds at
runtime.

## Relationship to upstream

This is an unofficial rebuild. It is not endorsed by, supported by, or
affiliated with the Lightpanda project. Please do not file issues about these
binaries on the upstream tracker.
