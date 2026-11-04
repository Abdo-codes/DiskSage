# DiskSage

DiskSage is an open-source macOS menu-bar app that finds regenerable developer
files, offers Claude, Codex, Apple on-device, and Ollama cleanup advisors, and keeps
provides configurable cleanup controls.

The dashboard shows a live disk-capacity ring, estimated cleanup sizes by
category, and recent logged activity. Available space follows macOS important-use
capacity and may include purgeable space. Cleanup estimates are scan candidates,
not a partition of disk usage. The panel is anchored to its menu-bar button;
reopening the app from Applications also reveals it.

The compact dashboard separates low-risk candidates from items needing careful
review. **History** shows completed cleanup runs, the items removed or refused,
and their timestamps. Routine monitoring checks remain in the full log. Removed
item size estimates and the observed change in available space are shown
separately because filesystem reclamation and other apps can affect free space.

## Safety model

- Scanning is deterministic; the agent never discovers filesystem paths.
- Every agent receives metadata only: a random candidate ID, category, size, risk,
  and the scanner's generic reason. Paths and project names stay local.
- Codex uses an ephemeral read-only sandbox. Claude runs without tools, MCP
  integrations, user customizations, or session persistence. Apple and Ollama
  receive no filesystem tools.
- Agent output can only refer to IDs the scanner already produced.
- A local allowlist validates every path again immediately before deletion.
- Descriptor-relative deletion rejects symlink swaps, identity changes, and
  mounted-filesystem boundaries between scanning and deletion.
- Git directories, broad roots, unknown paths, and symlinks are refused.
- Archives and simulator devices are marked high-risk and never auto-selected
  from an agent recommendation.
- Manual deletion requires confirmation in the review window. Optional low-disk
  automation only removes scanner-classified low-risk, regenerable items.
- `~/.cache` and `Library/Caches` subfolders are classified low-risk as
  regenerable caches, but a few command-line tools keep non-regenerable data
  there. Review items under those roots before enabling automatic cleanup.

## Requirements

- macOS 14 or later
- Xcode 27 or a compatible Swift toolchain
- Optional: Claude Code or Codex CLI installed and signed in
- Optional: Apple Intelligence enabled on a supported Mac with macOS 26 or later
- Optional: Ollama running on localhost:11434 with an available text model

No API key is stored by DiskSage. CLI providers use your existing sign-in;
Apple uses the system on-device model, and Ollama uses the local service.

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

Cleanup progress shows completed target folders and a live count of removed files
and folders. Updates are throttled and delivered separately from filesystem work,
so UI processing does not block deletion. Up to four independent targets are
removed concurrently. Overlapping targets preserve their input order; simulator
cleanup runs alone. Large individual trees can still take time because
macOS must unlink their entries individually.

## Architecture and workflow tests

A single application-owned TCA `AppFeature` store coordinates scanning, advisor
requests, confirmation, manual and automatic cleanup, and MCP jobs. `AppModel`
is a temporary AppKit/SwiftUI adapter: it reads store state and sends actions,
without separate workflow state or tasks. Native windows and panel positioning
remain in AppKit; review filters and settings still use their existing local
state and preferences during this first migration slice.

Scanner, advisor, cleanup, capacity, history, and preference access are injected
through `DiskSageClient`. Every operation has an identity; stale responses are
ignored. Read operations are cancellable, while deletion stays owned by the
persistent root store. `TestStore`, controlled streams, and `TestClock` cover
operation arbitration and hourly monitoring without polling or real-time sleeps.
The existing filesystem, parallel-deletion, logging, and provider tests remain.

## Cleanup logs

Choose **Open Cleanup Logs** in the menu-bar window to open
`~/Library/Logs/DiskSage`. The local `cleanup.jsonl` log records timestamps,
manual, automatic, or agent triggers, each target path, successes and errors, and a run
summary. Hourly checks also record why automatic cleanup ran or was skipped.
An item-start event without an item-finished event means the outcome is unknown
(for example, the app quit during deletion). A failed item may have been partially
removed before an error occurred.

The summary separates the estimated size of removed targets from the observed
change in available disk space, which other apps can also affect. Logs rotate at
5 MiB, retaining one previous file, and are readable only by your macOS user.
They stay local and are never sent to an agent. If logging fails, cleanup stops
scheduling new targets and displays the logging error. Already-started workers
finish safely, and their results are reconciled before the run returns.

## Review and settings

The review window supports search by name or path, risk filters, selecting visible
low-risk items, and clearing all selections. Filtering preserves hidden selections
and explicitly counts them in the footer; the deletion confirmation includes all
selected paths. Use the info button beside an item's risk to see its reason and
deletion scope; both also appear in the final confirmation. Cancel is available
while scanning or asking an agent, including automatic preflight scans. Automatic
cleanup rechecks its setting, threshold, and free space after scanning before it
starts deleting.
Use Command-1 for Review, Command-comma for Settings, and Command-W to close
the current window. Standard window commands are also available in the menus.

Settings has separate **Agent**, **Agent Tools**, and **General & Safety** tabs. Advanced executable
paths and custom model IDs are collapsed by default. Claude also offers model
presets. Review actions check CLI, Apple model, or selected Ollama model readiness
and offer **Set Up Agent…** when unavailable. CLI detection does not verify sign-in.
Cancelling a scan stops its background traversal, and targets that fail
the deletion policy are excluded from scan results. Deletion still validates each
target again immediately before removal.

## Clean now and connected agent tools

**Clean Low-Risk Items…** in the dashboard and app menus runs the same low-risk
selection as scheduled cleanup, regardless of the free-space threshold. It scans
if needed, opens Review, and asks for confirmation before permanent deletion.

DiskSage also provides a local [MCP stdio server](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
for Claude Code, Codex, and compatible clients. Keep the GUI app running; each
client's `--mcp` process forwards commands over a private, same-user Unix socket
to the shared app model. Tools cannot supply paths or risk overrides.

After installing the app at `/Applications/DiskSage.app`, connect either client:

```sh
claude mcp add --transport stdio --scope user disksage -- /Applications/DiskSage.app/Contents/MacOS/DiskSage --mcp
codex mcp add disksage -- /Applications/DiskSage.app/Contents/MacOS/DiskSage --mcp
```

Restart an existing client session to discover newly registered tools.
**Settings → Agent Tools** also provides copyable commands using the running
app's executable path. Codex setup follows the [official MCP command format](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
Server readiness is shown separately from client connection status, which is
managed in the agent.
**Settings → Agent Tools** controls cleanup authorization: **Confirm in DiskSage**
by default, **Disabled**, or **Allow low-risk cleanup** for unattended requests.
This choice is separate from hourly low-disk automation. Enable **Allow built-in
advisors to request cleanup** to extend it to the selected Claude, Codex, Apple,
or Ollama advisor. The button then reads **Review & Clean**. Providers can return
a structured `cleanupRequested` host-tool request after metadata review. The app
validates the response, requires at least one low-risk delete recommendation,
then dispatches the same fresh-scan `clean_low_risk` action. Providers have no
filesystem access and do not inherit other MCP integrations.

| Tool | Arguments | Result |
| --- | --- | --- |
| `get_status` | `{}` | Free space, aggregate counts, busy state and cleanup policy |
| `scan` | `{"request_id":"<UUID>"}` | Starts a fresh scan and returns a job |
| `clean_low_risk` | `{"request_id":"<UUID>"}` | Fresh scan, then low-risk cleanup under the configured policy |
| `get_job` | `{"request_id":"<UUID>"}` | Progress or a final result for that job |

Use a new UUID for each new scan or cleanup. Retry the same action with its
original UUID to retrieve its existing job without starting another run.
Poll `get_job` until `succeeded`, `warnings`, or `cancelled`; a request being
accepted does not mean deletion completed. `awaitingConfirmation` requires the
user to approve or cancel in DiskSage. Busy requests are rejected, not queued.
Only the last 100 jobs in the current app session are retained. An unknown ID
after restart or eviction is not proof of cleanup; inspect local history before
starting another request. Disconnecting an agent does not cancel deletion.

Tool replies include totals, timestamps, and sanitized failures, without paths
or project names. Full per-item details stay in local cleanup history and logs.
Agent deletions are logged with the **Agent** trigger and use the existing
allowlist, identity, symlink, mounted-filesystem, and mandatory logging checks.

## Agent choices

Choose **Settings → Cleanup Agent** to select Claude, Codex, Apple on-device,
or Ollama. Each remote-capable provider has its own metadata consent setting;
approving Codex does not approve Claude or Ollama. Changing agents never deletes
anything. Only low-risk delete recommendations can be selected automatically.

Claude requires `claude auth login`. It runs a bounded `claude --print` request
with JSON output, no built-in or MCP tools, safe mode, no user/project settings,
and no session persistence. Codex retains its ephemeral read-only `codex exec`
integration. Both providers support an executable and model override.

Apple uses Foundation Models guided generation on-device, in small independent
batches. Settings explains unsupported hardware, disabled Apple Intelligence,
and model downloads that are not ready. It never falls back to a remote agent.

Ollama discovers text models from `http://127.0.0.1:11434/api/tags`. Refresh and
choose a model in Settings. Cloud models are labelled **Cloud**; they may send
metadata off the Mac despite using a localhost endpoint. Local models are
labelled **Local**. DiskSage does not pull or download models. Local generation
uses a JSON schema; cloud output is prompted as JSON and validated locally.

Every provider must return exactly one recommendation per scanned ID, with no
unknown or duplicate IDs. Invalid or cancelled responses leave the selection
unchanged. Requests time out after 90 seconds and can be cancelled. Cleanup
logs remain local and are not included in agent requests.

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
