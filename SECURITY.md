# Security Policy

DiskSage permanently deletes files, so safety issues are treated as security
issues. Please report path-validation bypasses, symlink races, overly broad
cleanup candidates, or agent-boundary problems privately to the maintainer
before public disclosure.

## Design guarantees

- Built-in advisor recommendations never become filesystem paths. Their payloads
  remain metadata-only, including when advice is requested through MCP.
- Scanner/agent cleanup targets use the local allowlist. Scheduled custom folders
  use a separate, explicit authorization bound to the chosen folder's identity.
- Broad roots, system folders, target paths under Git data, app bundles, and
  DiskSage's running executable/settings/log directories cannot be scheduled.
- Symlinked target paths and ancestors are refused. Descriptor-relative deletion
  does not follow child symlinks or cross mounted-filesystem boundaries.
- Built-in CLI advisors use ephemeral restricted sessions with filesystem tools
  unavailable. External MCP clients are separate applications; DiskSage validates
  their requests at the local socket and again in the shared coordinator.
- Built-in advice never selects high-risk items automatically. MCP clients may
  review/select those scanned IDs, but deletion always needs native confirmation.
- MCP cannot approve confirmations, authorize arbitrary folder deletion, grant
  provider consent, or change its own access policy without local approval.
- Schedule edits require current revisions. Completed schedule mutations and
  their retry receipts are saved atomically; retries cannot reapply old changes.

The full authorization and retry contract is in [MCP tools](docs/MCP.md).
