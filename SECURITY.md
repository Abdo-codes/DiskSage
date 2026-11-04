# Security Policy

DiskSage permanently deletes files, so safety issues are treated as security
issues. Please report path-validation bypasses, symlink races, overly broad
cleanup candidates, or agent-boundary problems privately to the maintainer
before public disclosure.

## Design guarantees

- AI recommendations never become filesystem paths.
- Every deletion target is validated locally against an allowlist.
- Broad roots, Git data, symlinks, and DiskSage's running executable tree are
  refused.
- Agent sessions are ephemeral, ignore unrelated user configuration, and use a
  read-only sandbox.
- High-risk candidates are never selected automatically by an agent response.
