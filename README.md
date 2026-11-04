# DiskSage

DiskSage is an open-source macOS menu-bar app that finds regenerable developer
files, asks your locally authenticated Codex agent for cleanup advice, and keeps
the final deletion decision in your hands.

## Safety model

- Scanning is deterministic; the agent never discovers filesystem paths.
- Codex receives metadata only: a random candidate ID, category, size, risk,
  and the scanner's generic reason. Paths and project names stay local.
- The Codex session is ephemeral and uses a read-only sandbox.
- Agent output can only refer to IDs the scanner already produced.
- A local allowlist validates every path again immediately before deletion.
- Descriptor-relative deletion rejects symlink swaps, identity changes, and
  mounted-filesystem boundaries between scanning and deletion.
- Git directories, broad roots, unknown paths, and symlinks are refused.
- Archives and simulator devices are marked high-risk and never auto-selected
  from an agent recommendation.
- Manual deletion requires confirmation in the review window. Optional low-disk
  automation only removes scanner-classified low-risk, regenerable items.

## Requirements

- macOS 14 or later
- Xcode 16 or a compatible Swift 6 toolchain
- Optional: Codex CLI installed and signed in (`codex`)

No API key is required. DiskSage calls `codex exec` using the user's existing
local Codex authentication.

## Build

```sh
git clone <repository-url>
cd DiskSage
./Scripts/build-app.sh
open .build/release/DiskSage.app
```

For development:

```sh
swift test
swift run DiskSage
```

The Settings window can launch DiskSage at login and automatically clean safe
items when available disk space falls below a configurable threshold (15 GiB by
default). Archives, simulator devices, and generic `build` directories are
never included in automatic cleanup.

## How the agent integration works

DiskSage launches a bounded `codex exec` job with `--ephemeral`,
`--sandbox read-only`, a minimal environment, and `--ignore-user-config`. It
requests schema-validated structured
recommendations for the scanned candidate IDs without loading unrelated MCP
servers, plugins, or project instructions. The app ignores unknown IDs and does
not expose a deletion tool to the agent. The request times out after 90 seconds
and can be cancelled from the app.

## Release artifacts

Tagged builds are produced by GitHub Actions as an ad-hoc-signed zip with a
SHA-256 checksum. For public distribution without Gatekeeper warnings, configure
Developer ID signing and Apple notarization before publishing a stable release.

For a richer chat experience, future versions can adopt Codex app-server while
keeping the same scanner and deletion-policy boundary.

## Contributing

Issues and pull requests are welcome. Please include tests for any change to
the scanner or safety policy. New cleanup locations must be narrowly scoped,
regenerable, and explicitly added to `SafetyPolicy`.

## License

MIT
