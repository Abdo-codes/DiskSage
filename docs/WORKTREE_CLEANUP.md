# Git worktree cleanup

Worktree cleanup starts with manual review. Disposable Git fixtures cover explicit
discard, stale approval, ignored-file consent, nested repository isolation, and
complete file walking.

The implementation uses bounded offline inspection and conservative blockers.
Choose approved folders in **Cleanup Review → Git Worktrees**. No existing folder
scope or worktree is selected automatically. Native removal retains local refs;
MCP uses the same confirmation and executor. Current limits: 30,000 discovery
entries, depth 5, 150,000 checkout entries, 500 retained refs, 200 recovery tips,
20 seconds / 8 MB per inspection process, and 300 checkouts per removal batch, 100 worktrees per repository and 300 linked checkouts total. Standalone clones
are excluded, and primary checkouts in linked families are hidden by default. A limit blocks
inspection instead of certifying incomplete evidence. An already-started native
Git removal is allowed to finish; its output read is bounded. Unsupported filter/sparse/
partial configurations and custom worktree-local settings remain blocked.
Normal `extensions.worktreeConfig`, matching checkout roots and inert core flags
are supported; enabling that Git feature alone is not a blocker. Borrowed object stores,
grafts and symlinked Git objects are blocked; shared object checks stop at 50,000
entries. Replacement refs are disabled during inspection. Process observations are
incomplete and never establish that all editors or agents stopped.

## Outcome

Add a **Git Worktrees** section to Cleanup Review, grouped by repository. Help
people reclaim obsolete checkouts while preserving source changes and commits.
The default action is **Remove checkout, keep branch**. Removing a checkout does
not establish that its commits are backed up remotely.

Worktrees are never selected by **Select Low Risk**, low-disk automation,
`clean_low_risk`, built-in advisor cleanup requests, or folder schedules. Existing
cleanup of recognized generated directories inside worktrees remains separate.

## What the review shows

- Repository, branch or detached HEAD, checkout path, and estimated folder size.
- Separate counts for staged, modified, conflicted, untracked, and ignored files.
- Commits ahead/behind the recorded upstream; no upstream is **Unknown**, not zero.
- Whether HEAD is contained in a user-selected integration reference, with its OID.
- Which commits are absent from the locally recorded remote references.
- Whether a retained local branch/tag protects the commits and recovery history.
- Git lock/protection, in-progress operations, and known activity signals.
- Analysis time, evidence freshness, incomplete checks, and explicit reasons.

Labels describe evidence: **Clean**, **Uncommitted changes**, **Local-only commits**,
**Not proven merged**, **Detached**, **Locked**, **In use**, or **Unknown**.
Age and last commit date are ranking hints; neither proves a checkout is unused.
Git alone cannot reliably detect every editor, terminal, agent, or running build.

## Eligibility and treatment

All eligible rows still require native confirmation; nothing is preselected.
The following conditions compose: a favorable commit status cannot override a
file, identity, activity, or metadata blocker.

| Evidence | V1 treatment |
| --- | --- |
| Clean and HEAD contained in the selected integration reference | Recommend for review if every other check passes; keep branch |
| Clean, pushed according to recorded remote refs, but not merged | Additional review of commits; checkout removal can proceed with retained local refs |
| Clean with commits absent from recorded remote refs, or no upstream | Explain that commits remain local; allow only after verifying retained local refs and explicit acknowledgement |
| Staged/modified/conflicted or untracked files | Exclude from quick cleanup; allow exact manual destructive review and separate discard approval |
| Recognized ignored generated output | Show its paths/size explicitly as included in removal; require acknowledgement |
| Ignored content, including `.env`, local notes, or credentials | Show the full file inventory and size estimates; require separate explicit native approval for permanent deletion. Ignored does not mean disposable |
| Detached or recovery-only commits without retained shared named refs | Exclude from quick cleanup; warn they may become unrecoverable and require separate discard approval |
| Main checkout, Git-locked, app-protected, known active, or in-progress operation | Exclude from removal |
| Nested repositories and private Git metadata | Show what will be lost; separate discard approval required; nested branches are not retained |
| Submodules, unsafe paths, unreadable/incomplete Git state | Unsupported or blocked, with a reason |
| Sparse checkouts or index/configuration flags that can hide working-file changes | Block unless complete file-state analysis is supported and tested |
| Missing/prunable registration | Show separately as metadata-only; claim no checkout disk savings |

Retained refs must be shared named refs that survive removal, not the worktree's
HEAD, private refs, or its reflog. Inspect worktree-only recovery tips and local
metadata before claiming preservation. Shared stashes remain untouched; their
existence does not prove this worktree's files have been saved.

## Review flow

1. Choose repository discovery roots or add a repository explicitly.
2. Open **Cleanup Review → Git Worktrees** and select a repository/worktree.
3. Inspect changed paths, ignored content, commit lists, and protection reasons.
4. Use **Reveal in Finder**, **Open in Terminal**, **Refresh local status**, or
   **Keep this worktree**. A cache-only action uses the existing cache workflow.
5. Select eligible checkouts and choose **Remove Worktrees…**.
6. Confirm exact paths, included ignored output, estimated size, retained branch
   names/OIDs, and any local-only commits. Confirm the checkouts are no longer in use.
7. Revalidate immediately before removal; changed evidence requires a new review.
8. Show per-worktree results. Remove successful rows, keep failures actionable,
   and refresh the repository after the batch. Keep progress owned by the app.

Confirmation explicitly states that checkout files are permanently removed,
branches are retained, and source checkout removal cannot be undone by DiskSage.
Keeping commits is not a backup of ignored/untracked files or worktree-local settings.

### Explicit discard review

Manual selection accepts fully inspected rows with data-loss warnings. MCP must
opt in with `allow_discard: true` when previewing them. This is a review request,
not permission to delete. The native sheet lists warnings and searchable changed
paths. Untracked directories include all their contents. Disposable worktrees use one Delete button. Actual unsaved/private data adds one
explicit acknowledgement; there is no typed phrase.

Private Git metadata is fingerprinted, including file contents; the full checkout
manifest pins nested repository data and untracked directory contents. Changed
facts invalidate approval. The executor journals the approval and logs the discard
risks before Git runs. Only top-level branch refs and shared Git data are retained.
MCP summaries show the first three risks and a count; all risks remain available
through paged inspection and the native review. A repository-scoped refresh accepts
only an existing repository inside approved folders and preserves the full scope
policy. Its post-removal refresh stays scoped; Show All Repositories restores the
broad review. Refresh updates existing rows and appends discoveries. Rows absent
from the latest inspection stay visible and require fresh evidence before removal.
No automatic or quick-unused route opts into discarding data. Nested clones must
be isolated: at most 100 nested repositories, with no shared Git data outside the
parent or additional/protected/locked registrations. These remain hard blockers.

### Quick cleanup and ignored-file approval

**Clean Unchanged Worktrees…** gathers disposable checkouts, up to 300
per batch with a bounded approval payload. “Unused” is confirmed by the person;
Git and process observations alone cannot establish it. Unmerged/local-only work
may be reviewed because verified local branches/tags remain. The shortcut does
not delete anything until native confirmation, and closing review cancels its
queued presentation. A cold shortcut loads evidence first.

After confirmation, the sheet closes and removal continues in the application
store. Browsing, selection, switching sections and closing the review window stay
available. The inline progress banner can cancel queued worktrees; the current
Git removal finishes. New selections apply to the next cleanup.

Ignored files are enumerated without loading contents. Review provides searchable,
paginated paths, estimated allocated bytes and symbolic-link labels. The native
acknowledgement is recorded in the approval journal and required again by the
executor. Agents cannot supply it. A changed ignored-file manifest, including a
new file under an already-ignored directory, invalidates the approval. Tracked
source changes and untracked files outside generated caches require discard review; activity, locks and other hard safety blockers remain.

Bulk inventory shares read-only object-storage checks within each repository
and batches recovery-tip reachability. Removal always performs fresh checks.

## Git inspection and discovery

- Discover repositories within approved roots, skipping dependency/build trees.
  Deduplicate by verified common Git directory, not repository/branch basename.
- Use `git worktree list --porcelain -z` as the registered-worktree authority.
  Verify ownership, canonical paths, common directory, administrative entry, and
  device/inode identity. A `.git` file alone is insufficient authorization.
- Worktrees discovered outside approved roots require explicit inclusion before
  becoming removal candidates. Do not interpret arbitrary folders as worktrees.
- Parse NUL-delimited status, including staged/unstaged/conflicted/untracked data,
  ignored paths, and submodule state. Preserve unusual filenames without shell parsing.
- Inspect index flags such as `assume-unchanged` and `skip-worktree`; ordinary status
  must not certify hidden changes as clean. Unsupported sparse/hidden state blocks
  removal rather than changing the user's index flags to make it inspectable.
- Use full OIDs and Git reachability against explicitly resolved references.
  Support both SHA-1 and SHA-256 repositories; do not assume `origin/main`.
- Treat ahead/behind, integration, and remote containment as separate facts.
  A commit existing somewhere remotely does not mean it was merged into the target.
- A squash/rebase merge can fail the ancestor test. Label it **Not proven merged**;
  do not infer success from matching trees, commit titles, or AI recommendations.
- V1 inventory is local and offline. Label remote-tracking facts as cached, with
  unknown freshness when no trustworthy verification exists. No background fetch,
  credential prompts, or assumption that a missing upstream means unpublished work.
- Bound inspection time/output and use cancellable background work. Timeout,
  inaccessible paths, missing objects, shallow/partial history, or unsupported
  metadata produce explicit incomplete evidence rather than optimistic clearance.
- Constrain Git subprocesses: verified executable, structured arguments, controlled
  environment, optional locks disabled for inspection, no lazy network fetch, and
  no repository-configured executable helpers during scanning. Validate these
  properties with adversarial fixture configuration before enabling discovery.

## Removal and preservation contract

Use a dedicated `WorktreeRemovalPolicy` and `GitWorktreeClient`, not generic
recursive deletion. The existing `SafetyPolicy` Git-data restriction stays intact.
Git documents that normal removal rejects dirty worktrees and that the main
checkout cannot be removed; DiskSage adds its own preservation checks before it.
See the [Git worktree reference](https://git-scm.com/docs/git-worktree).

Execution uses native `git worktree remove` for the exact registered path. Ordinary
review never forces removal. A snapshot containing explicit discard risks permits
one `--force` only after native confirmation of the exact scope.
Do not double-force or fall back to recursive removal after Git refuses. Do not delete
branches, unlock worktrees, reset, stash, clean files, prune registrations, expire
reflogs, or garbage-collect repository objects as part of this action.

Before each removal, recheck path/admin identities, HEAD, retained refs, complete
status, ignored inventory, locks, operation state, and activity evidence. Pin this
evidence in the approval snapshot. Abort on changes or new uncertainty.

Retain branch refs at their approved OIDs and verify them after removal. Git may
remove worktree-specific metadata, so recovery-only history and unique local
settings need explicit preservation or discard review before removal.

Serialize mutations sharing a common Git directory; bound parallelism across
repositories. Reuse the app's operation gate so cache cleanup, schedules, and
worktree removal cannot compete. Cancel queued removals; once deletion starts,
let the app-owned operation finish and reconcile its outcome.

External Git/editor/agent processes do not share DiskSage's lock. Fresh checks and
Git's own refusal help but cannot make the entire operation atomic against them.
Require the user to stop work first; known active leases/processes block removal.
Do not describe unknown activity as verified inactivity.

Exclude worktree roots and ancestors containing them from generic folder cleanup
and schedules, with fresh checks at execution. Preserve existing generated-child
cleanup. This closes a bypass around the new source-preservation review.
This also conservatively blocks cache containers containing dependency Git clones;
choose a narrower generated child folder. No clone exception bypasses review.
Existing schedules that violate the new guard become visibly paused with a reason
and require a fresh folder choice; do not silently change their deletion scope.

## Space accounting and history

Count checkout files, including reviewed generated output, not the shared Git
object database. Deduplicate parent worktrees and nested cache selections.
APFS shared extents/hardlinks mean estimates are not guaranteed physical savings.
Report estimated removal and observed net free-space change separately.

Persist intent before deletion. Record repository/worktree identity, path, branch,
HEAD/ref OIDs, analysis version, approval, result, errors, and space observations.
Do not log file contents, secrets, or credential-bearing remote URLs.

Git failures can leave partial filesystem changes. Reconcile the registration,
remaining directory, and refs instead of assuming all-or-nothing success. A crash
after execution must not cause an unconditional retry or a false success claim.

## Architecture and MCP

Keep this a separate domain from regenerable caches:

- `GitRepositoryIdentity`, `GitWorktree`, `WorktreeInspection`, `WorktreeRemovalPreview`.
- Explicit inspection facts plus a deterministic policy producing eligibility,
  blockers, and acknowledgements. Never encode source safety as just `RiskLevel.low`.
- A testable Git client for discovery/inspection/removal with native Git fixtures.
- A TCA `WorktreesFeature` for loading, filters, selection, preview, confirmation,
  progress, stale evidence, cancellation, and partial failures.
- A separate Worktrees review view/controller; avoid growing the current app
  delegate, which is already close to the 350-line project limit.
- A typed worktree authorization routed through the shared operation gate and
  history. Do not pass worktree roots through `SecureDeletionService`.

MCP/UI parity uses the same policy and reducer. Proposed tools:

| Tool | Purpose |
| --- | --- |
| `list_worktrees` | Paginated inventory and analysis timestamps |
| `inspect_worktree` | File/commit facts, reference snapshots, blockers, size |
| `preview_worktree_removal` | Exact proposed scope plus an opaque snapshot token |
| `preview_unused_worktrees` | Prepare the same eligible batch as the UI shortcut; inactivity and ignored-file deletion still require native confirmation |
| `remove_worktrees` | Start a job using IDs/snapshot token; always require native human approval |
| `set_worktree_protected` | Manage app protection; removing protection requires human approval |

Mutation UUIDs are durable/idempotent; changed arguments or stale snapshots are
rejected. Agents cannot pass arbitrary deletion paths, force flags, approve their
own requests, or reuse the low-risk automation permission for worktrees.
Snapshots and logs remain inspectable through MCP. Built-in advisors receive
only consented, redacted metadata and cannot override hard Git/policy blockers.

## Delivery sequence

1. **Read-only inventory:** Git client, evidence model, deterministic classification,
   fake/native Git fixtures, and Worktrees review UI. Inspection remains independently callable.
2. **Manual removal:** typed authorization, revalidation, native Git executor,
   operation gate, history/reconciliation, and source/schedule bypass protections.
3. **MCP parity:** inventory/preview/protection/removal tools using the same flows;
   review and test that agents cannot bypass native approval.

Later, separately scoped: recovery branches/bundles, verified remote/provider PR
facts, cooperative agent leases, stale-registration cleanup, and optional automation.
No automatic worktree removal or automatic preservation/branch changes in V1.

## Acceptance and regression coverage

Use disposable native Git repositories plus TCA tests; never real user worktrees.

- Clean merged checkout: explicit confirmation removes it and its registration;
  retained branch OID and shared repository remain unchanged.
- Clean unmerged/local-only work: explain local retention; preserve refs and require
  acknowledgement. Missing upstream/remote data never becomes a zero-risk badge.
- Ignored secrets require separate native approval; changed ignored files invalidate it.
- Staged, modified, conflicted, untracked, nested repo, private metadata and
  unanchored detached/recovery tips: require separate native discard approval.
- Submodules and merge/rebase/bisect state: prevent removal even with discard approval.
- Sparse checkout, intent-to-add, `assume-unchanged`/`skip-worktree`, and configuration
  that suppresses changes cannot produce a false clean/preserved result.
- Ignored generated output is visible in scope/size and requires acknowledgement.
- Main, locked, protected, known-active, or missing/offline worktrees are excluded;
  unknown activity is not reported as inactive. No automatic pruning occurs.
- Squash/rebase integration, stale tracking refs, no upstream, shallow/partial
  clones, missing objects, and SHA-256 repositories preserve uncertainty correctly.
- Dirty edit, branch/HEAD change, lock, lease, or path/identity substitution after
  preview invalidates approval. Test changes between preflight and Git invocation.
- Newline/tab/space/Unicode/dash filenames and paths survive parsing; executable
  repository configuration cannot run as a side effect of inspection.
- A refused/partial removal preserves other rows, releases the operation gate,
  retains failures, and refreshes facts. Restart/retry cannot repeat blindly.
- Duplicate mutation IDs, forged paths/snapshots, force flags, low-risk cleanup,
  and generic schedules cannot bypass worktree-specific checks or human approval.
- Existing unsafe folder schedules are paused on migration with an explanation.
- Parent/cache overlap does not double-count space or launch competing deletions.
- Native Mac review covers keyboard/VoiceOver, long paths, commit/file drill-down,
  busy/empty/error states, readable confirmation, and visible per-row results.

## References

- [Git worktree registry/removal semantics](https://git-scm.com/docs/git-worktree)
- [Git status porcelain, ignored files, and submodules](https://git-scm.com/docs/git-status)
- [Ancestor tests](https://git-scm.com/docs/git-merge-base)
- [Commit reachability and patch-equivalent comparisons](https://git-scm.com/docs/git-rev-list)
- [Index flags that affect working-file inspection](https://git-scm.com/docs/git-update-index)

### Disposable worktrees

Quick cleanup excludes meaningful unsaved files, secrets and unretained commits.
Generated build/cache paths and a valid, retained `CLAUDE_BASE` marker are eligible.
Nested dependencies must be isolated and clean, with HEAD reachable from cached
remote refs; bare generated dependency mirrors are eligible. Local edits, ignored
settings or unique dependency commits require review. Evidence and classification
are pinned together and rechecked before deletion. The selection is bounded to
300 worktrees and 16 MB of inspection data; previews summarize large selections
while the native sheet keeps the complete list. Reference verification is batched
after each removal.
