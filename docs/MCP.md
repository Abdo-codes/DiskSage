# DiskSage MCP tools

The stdio server is a bridge to the running GUI app. It uses the same TCA store,
scanner, scheduler, deletion coordinator, settings, and logs. Open DiskSage first.
Existing Claude Code and Codex setup commands remain valid. Restart or reconnect
the client after updating DiskSage to discover new tools.

Optional guided setup is available on first launch and under **Settings → About →
Connect an agent**. No skill package is needed. Its verification step waits for a
fresh tool request received by the GUI; this does not verify advisor authentication.
**Settings → MCP** provides one-click registration for installed Claude Code and
Codex CLIs, a copyable stdio JSON entry for other clients, connection verification,
and cleanup access controls. Registration preserves conflicting existing entries.

Schemas are maintained in `MCPServer.swift` and `MCPManagementSchema.swift`.
The protocol follows the [MCP tools specification](https://modelcontextprotocol.io/specification/2025-06-18/server/tools).
Unknown keys, malformed identifiers, permission overrides, and remote paths are
rejected. Successful replies include both MCP `structuredContent` and equivalent JSON text.
Check `isError` before parsing: connection errors can contain only text.

## Functional parity

| App capability | MCP tools |
| --- | --- |
| Disk dashboard, progress, errors, pending confirmations | `get_status`, `get_dashboard` |
| Fresh scan | `scan` |
| Git worktree inventory and file/commit details | `refresh_worktrees`, `list_worktrees`, `inspect_worktree` |
| Preview/request checkout removal (native confirmation always) | `preview_worktree_removal`, `preview_unused_worktrees`, `remove_worktrees` |
| Keep/unprotect a worktree (unprotect needs native approval) | `set_worktree_protected` |
| Search/filter candidates, inspect risk and deletion scope | `list_candidates` |
| Replace/add/remove selection, clear selection | `set_selection` |
| Reveal selected candidate in Finder | `reveal_candidate` |
| Clean low-risk items under the app's agent policy | `clean_low_risk` |
| Request selected-item deletion, including sensitive items | `delete_candidates` |
| Cancel scanning/advice; decline confirmations | `cancel_operation`, `dismiss_confirmation` |
| Create/list/edit/pause/resume/remove folder schedules | `create_schedule`, `list_schedules`, `update_schedule`, `pause_schedule`, `remove_schedule` |
| Read/change all General, Agent, and MCP access settings | `get_settings`, `update_settings` |
| Provider configuration/readiness and model choices | `list_advisors`, `list_models` |
| Ask Claude, Codex, Apple, or Ollama for advice | `request_advice` |
| History and individual cleanup log events | `get_history`, `get_logs` |
| Connection commands and read-only verification prompt | `get_mcp_setup` |
| Open app screens/log folder; quit | `open_window`, `quit_app` |

Presentation-only actions such as resizing a window are handled by macOS.
The API returns setup text instead of copying to the clipboard. Launch-at-login
registration can still require approval in macOS System Settings.
`get_dashboard` also exposes app version/project metadata in `app` and the most
recent client request timestamp in `last_mcp_contact` (null before any request).
It also exposes `automatic_monitoring`, `automatic_check_interval_seconds`, and
`automatic_retry_after` for diagnosing low-space monitoring and its scan cooldown.
`storage_notifications` reports registered macOS low-space notification names and
registration failures; the one-minute fallback remains active independently.

## Requests, results, and retries

- Every mutation and asynchronous read needs a fresh UUID `request_id`.
- Retry only the identical request with its original UUID. Reusing an ID for
  different arguments is rejected.
- Synchronous reads return `data`. Work/mutations return `job`; completed output
  is in `job.result`. Poll `get_job` with the original request ID.
- Terminal job phases are `succeeded`, `warnings`, `failed`, and `cancelled`.
  `loading`, `scanning`, `advising`, `cleaning`, and `awaitingConfirmation` are
  not completion. A successful `get_job` call can describe failed work: inspect
  its phase and result.
- No tool approves a confirmation. `dismiss_confirmation` can only decline.
  Read the current confirmation ID from `get_dashboard`.
- Accepted deletion is not completed deletion. Use the final job counts and
  local history to establish what was removed. Starts without finishes have an
  unknown outcome; failures can occur after partial removal.
- Busy `scan`/`clean_low_risk` requests should be retried with their original UUID.
  Failed management requests remain recorded for this session; use a new UUID
  after correcting the cause or arguments.
- The last 100 session jobs are retained. At most four asynchronous management
  reads may be outstanding. The last 200 completed schedule mutations are also
  stored atomically with schedules and survive app restarts. `get_job` can read
  those persisted results too.
- Replayed schedule results describe the original mutation, not current state.
  For example, replaying an old create after a user pauses the schedule does not
  re-enable it. Call `list_schedules` for current state. Pending human approvals
  are session-only; quitting before approval applies no change.
- Lists use `offset` and `limit` (default 20 for candidates, schedules, history;
  100 for logs). Follow `next_offset` until it is null. The byte budget may make
  a page smaller than the requested limit. Lists read current state; restart a
  listing if another client edits while you page. Use a new request UUID for each
  asynchronous page. Candidates/schedules/history allow at most 100 per page;
  logs allow 200. History retains up to 100 completed runs; use `get_logs` with
  `run_id` for item details. Logs are newest first and subject to rotation.

## Authorization

MCP clients can inspect candidate paths, schedules, settings, history, and logs.
Built-in advisors continue to receive only the metadata described in the README;
this MCP review access does not change their sandbox or prompt payload.

- **Allow low-risk cleanup:** recognized low-risk schedules can be activated
  directly. `clean_low_risk` follows the same configured policy.
- **Confirm in DiskSage:** agent-created/edited low-risk schedules are saved
  paused. Enable them in Settings → Schedules. This does not grant permission
  for unattended deletion merely because one cleanup was confirmed.
- **Disabled:** deletion and schedule creation/edit requests are rejected. Reads,
  selection, cancellation, and pausing/removing schedules remain available.
- All selected-item deletion requests require the existing permanent-deletion
  confirmation in Review, even for low-risk selected items.
- Custom all-contents schedules and changes to those schedules require a native
  approval window before being saved. The exact folder and timing are shown.
- Every settings patch requires native approval, including metadata consent,
  cleanup access, launch at login, models, and executable paths. A request can
  ask for a policy change; it cannot grant that access itself.
- Advice without provider consent requests native approval first. Changed
  provider configuration invalidates the pending consent request.
- Schedule revisions and pending settings snapshots prevent stale changes from
  overwriting intervening UI edits. Approval revalidates folder identity and
  future one-time dates. Turning agent access off revokes pending custom-folder
  approvals.
- Pausing/removing/editing a schedule cannot cancel deletion that already began.
  Scans/advice are cancellable; deletion finishes under the app coordinator.

## Schedule arguments

`create_schedule` requires `request_id`, `target`, and `frequency`.

| Argument | Values / meaning |
| --- | --- |
| `target` | `xcode_derived_data`, `bazel_cache`, `npm_cache`, or `folder` |
| `path` | Required only for `target=folder`: absolute existing local directory |
| `scope` | `lowRisk` (default) or `folderContents` (native authorization required) |
| `frequency` | `daily`, `weekly`, `once` |
| `hour`, `minute` | Required for daily/weekly, 0–23 and 0–59 |
| `weekday` | Required for weekly; Sunday=1 through Saturday=7 |
| `run_at` | Required for once; ISO 8601 timestamp with UTC offset or `Z` |
| `enabled` | Optional; defaults to true on create, preserved on update, subject to policy |

Preset paths resolve on this Mac and cannot take a path override. Other recognized
low-risk targets include individual children of `~/Library/Caches` or `~/.cache`,
and generated `.build`, `DerivedData`, or `derived-data` directories under
`~/Developer`. Generic `build` folders require custom-folder authorization.
Missing folders are not implicitly created or authorized. Chosen folders stay
in place; their contents are removed. Replaced folders need new authorization.
Broad roots, system folders, app bundles, Git paths, and DiskSage's own executable,
settings and logs cannot be scheduled for deletion.

Schedules run independently of the low-disk threshold while DiskSage is running.
Recurring times follow the Mac's time zone, including daylight-saving changes.
Missed runs execute once after launch/wake when the app becomes idle. Each due
occurrence is durably consumed before scanning, so restart cannot replay it.

Example: ask an agent to clean DerivedData daily at 02:00:

```json
{
  "name": "create_schedule",
  "arguments": {
    "request_id": "113ce176-5063-4a3a-abbb-f47ba4423bc1",
    "target": "xcode_derived_data",
    "frequency": "daily",
    "hour": 2,
    "minute": 0
  }
}
```

For Bazel, use a different request UUID and `target=bazel_cache`. Use a separate
schedule for each folder. To test configuration without cleanup, include
`"enabled": false`.

`list_schedules` returns each schedule's `id`, `revision`, `folder`, `scope`,
`frequency`, `hour`, `minute`, `weekday`, `oneTimeDate`, `isEnabled`, `nextRun`,
`lastRun`, `lastResult`, and `timeZoneIdentifier`. File-system identities remain
internal. These summary field names match the stored app model.

Editing requires the latest `schedule_id` and `expected_revision`:

```json
{
  "name": "update_schedule",
  "arguments": {
    "request_id": "ea513969-1d8e-4764-973c-d83539ca8954",
    "schedule_id": "113ce176-5063-4a3a-abbb-f47ba4423bc1",
    "expected_revision": 1,
    "hour": 3
  }
}
```

Unspecified fields remain unchanged. Changing `frequency` requires the complete
new timing fields. Set `target=folder` when changing `path`. Use
`update_schedule` with `enabled=true` to resume, subject to the current policy.
`pause_schedule` and `remove_schedule` require `request_id`, `schedule_id`, and
`expected_revision`. Removal deletes configuration, not folder contents.

## Other arguments

Read `tools/list` for complete strict schemas. Common examples:

| Tool | Arguments besides `request_id` when required |
| --- | --- |
| `get_dashboard`, `get_settings`, `get_mcp_setup`, `list_advisors` | None; no request UUID needed |
| `list_candidates` | Optional `query`, `risk` (`all`, `low`, `medium`, `high`), `offset`, `limit`; no request UUID |
| `list_schedules` | Optional `offset`, `limit`; no request UUID |
| `set_selection` | `candidate_ids`, `mode` (`replace`, `add`, `remove`) |
| `delete_candidates` | Nonempty `candidate_ids` from the current scan |
| `cancel_operation` | Current `operation_id` from the dashboard |
| `dismiss_confirmation` | Current `confirmation_id` from the dashboard |
| `list_models`, `request_advice` | `provider`: `claude`, `codex`, `apple`, `ollama` |
| `get_history` | Optional `offset`, `limit` |
| `get_logs` | Optional `run_id`, `offset`, `limit` |
| `reveal_candidate` | Current `candidate_id` |
| `open_window` | `window`: `dashboard`, `review`, `settings`, `schedules`, `history`, `logs`, `agent`, `mcp`, `general`, `about`, `onboarding`; `tools` remains an alias for `mcp` |
| `quit_app` | None besides the UUID; MCP is unavailable after quitting |

`set_selection` with empty IDs and mode `replace` clears the selection. Adding
filtered low-risk IDs preserves hidden selections, matching Review's behavior.
Old or unknown candidate IDs are rejected. Rescan to refresh IDs and identities.

`request_advice` uses the provider's configured model/path and current cleanup
request setting. If built-in cleanup requests are enabled, advice can start a
separate low-risk cleanup job under the current agent policy. Its completion is
not proof that subsequent cleanup finished; inspect the dashboard and history.
`list_models` never downloads models. CLI detection does not verify sign-in or
quota; Ollama model listing may fail independently of the app.

`update_settings` takes a nonempty `settings` object. Allowed keys:

- `automatic_cleanup_enabled` (boolean)
- `cleanup_threshold_gib` (5–100, in 5 GiB steps)
- `launch_at_login` (boolean)
- `agent_cleanup_policy` (`disabled`, `confirm`, `automaticLowRisk`)
- `built_in_cleanup_enabled` (boolean)
- `agent_provider` (`claude`, `codex`, `apple`, `ollama`)
- `codex_executable_path`, `claude_executable_path` (empty for auto-detection or
  absolute existing executable path)
- `codex_model`, `claude_model`, `ollama_model` (strings)
- `codex_metadata_consent`, `claude_metadata_consent`, `ollama_metadata_consent`
  (booleans)

Unknown keys are rejected. Settings are applied only after a person approves
those exact changes in the app. This API never returns credentials or performs
provider sign-in; account authentication remains in the provider's own UI/CLI.

## Git worktrees

First approve repository/project folders in **Cleanup Review → Git Worktrees**.
This authorizes local inspection only. No background fetch, pruning or branch
changes occur. Choose an explicit full integration ref, such as `refs/heads/main`,
in that review; cached remote refs have unknown freshness.

1. Call `refresh_worktrees` with a fresh UUID and poll `get_job`. Optionally pass
   `repository_root` to inspect one existing repository inside approved folders.
   This does not add folder permissions; omitting it scans all approved folders.
2. Page through `list_worktrees`. `inspect_worktree` accepts `worktree_id`, `offset`
   and `limit`; page its `details` to see changed/ignored paths, commits and refs.
3. Call `preview_worktree_removal` with eligible `worktree_ids` (at most 300), or
   `preview_unused_worktrees` to prepare the same bounded batch as the UI shortcut.
4. Pass its opaque `snapshot_token` and a new UUID to `remove_worktrees`.
5. A person must review and confirm exact paths in the app. Automatic low-risk
   permission cannot approve worktree removal. Poll the job for each result.

`set_worktree_protected` accepts `worktree_id`, `protected` and `request_id`.
Protecting takes effect immediately; removing protection needs native approval.
Use `open_window` with `window: "worktrees"` to open the review. Human confirmation
cannot be sent through MCP; `dismiss_confirmation` can decline it. While a batch
runs, `cancel_operation` with its dashboard `operation_id` cancels remaining queued
rows; an already running Git removal finishes and is reconciled.

`list_worktrees` distinguishes `can_remove` (ordinary review) from
`can_request_removal` (may require explicit discard approval). Inspect
`removal_warnings` and `discard_approval_required`. Summaries include the first
three warnings plus `removal_warning_count` and `removal_warnings_truncated`; page
`inspect_worktree` for every `removal_warning`. The native sheet retains the full
risk list. To request destructive review,
pass `allow_discard: true` to `preview_worktree_removal`. This only creates a
preview; it never grants approval. `preview_unused_worktrees` selects only `disposable: true` rows: saved source,
retained commits and recognized generated data. Anchored Claude markers and clean
dependency caches do not add extra confirmations. Local notes, secrets and unique
commits do. The native view lists the full selected scope; large preview replies
include a bounded sample plus `checkouts_total` and `checkouts_truncated`.

Only native `git worktree remove` is used. The app rechecks identity, files, refs,
private metadata, recovery history, locks and activity. Ignored files require their
own approval. Changes, private Git metadata, unretained recovery commits and nested
repositories outside known disposable caches require one native acknowledgement.
Disposable checkouts use a single Delete confirmation, without checklists or a
typed phrase. Native approval alone permits Git to use one `--force` flag. Nested repository branches can be lost; only
top-level branches/shared Git data are retained. Neither MCP arguments nor automatic
policy can grant these approvals. Changed evidence invalidates them. Hard blockers
(main/protected/locked/active checkouts, unsafe paths and incomplete inspection)
cannot be overridden. Nested repositories with outside shared data or additional
checkouts remain blocked. Git refusal never triggers a recursive fallback or second force.
Checkout removal keeps branches and shared Git data; local refs are not a remote
backup. Estimated checkout bytes and observed free-space change are separate.

Acceptance and results are private, durable records (last 200 MCP requests).
After a restart an incomplete request reports unconfirmed completion and cannot
resume automatically; refresh evidence and inspect History before a new UUID.
Preview tokens are session-only and invalidated by refresh. Generic cache cleanup,
advisor requests and folder schedules never remove worktree roots. Existing
unsafe schedules are paused with a reason and require a new folder choice.
