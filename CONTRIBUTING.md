# Contributing to DiskSage

Thanks for helping make developer disk cleanup safer.

## Development

```sh
swift test
swift run DiskSage
```

Before opening a pull request:

1. Add tests for scanner or deletion-policy changes.
2. Run `swift test`.
3. Confirm new candidates are regenerable and narrowly scoped.
4. Never allow agent output to introduce a filesystem path or trigger deletion.
5. Keep credentials, personal paths, and scan results out of fixtures and logs.

## Cleanup-location proposals

Include documentation showing who owns the directory, how it is regenerated,
and what user state could be lost. High-risk locations must remain manually
selected and require confirmation.
