# DiskSage MCP tools

The stdio server is a bridge to the running GUI app. It uses the same TCA store,
scanner, scheduler, deletion coordinator, settings, and logs. Open DiskSage first.
Existing Claude Code and Codex setup commands remain valid. Restart or reconnect
the client after updating DiskSage to discover new tools.

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
| Search/filter candidates, inspect risk and deletion scope | `list_candidates` |
| Replace/add/remove selection, clear selection | `set_selection` |
| Reveal selected candidate in Finder | `reveal_candidate` |
| Clean low-risk items under the app's agent policy | `clean_low_risk` |
| Request selected-item deletion, including sensitive items | `delete_candidates` |
| Cancel scanning/advice; decline confirmations | `cancel_operation`, `dismiss_confirmation` |
| Create/list/edit/pause/resume/remove folder schedules | `create_schedule`, `list_schedules`, `update_schedule`, `pause_schedule`, `remove_schedule` |
| Read/change all General, Agent, and Agent Tools settings | `get_settings`, `update_settings` |
| Provider configuration/readiness and model choices | `list_advisors`, `list_models` |
| Ask Claude, Codex, Apple, or Ollama for advice | `request_advice` |
| History and individual cleanup log events | `get_history`, `get_logs` |
| Connection commands shown in Settings | `get_mcp_setup` |
| Open app screens/log folder; quit | `open_window`, `quit_app` |

Presentation-only actions such as resizing a window are handled by macOS.
The API returns setup text instead of copying to the clipboard. Launch-at-login
registration can still require approval in macOS System Settings.

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
| `open_window` | `window`: `dashboard`, `review`, `settings`, `schedules`, `history`, `logs`, `agent`, `tools`, `general` |
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
