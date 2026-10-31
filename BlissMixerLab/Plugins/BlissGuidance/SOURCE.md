# Bundled shared guidance-host source

This directory is a source-only copy of
[`chrober/lms-bliss-guidance-host`](https://github.com/chrober/lms-bliss-guidance-host),
commit `4f001e3`.

It is bundled so the Lab release has no hidden Lyrion-plugin dependency. Refresh
it reproducibly from the authoritative checkout with:

```powershell
./scripts/sync-guidance-host.ps1
```

Only the host-neutral discovery, policy, and JSONL runtime code belongs here.
Native guidance providers are installed and released separately.

## Research-branch-only SPI-v2 anchor forwarding patch

On branch `test/spi-v2-anchor-forwarding-vendor`, the existing vendored
`Runtime.pm` includes the **single provider-neutral anchor forwarding fix**
from [`lms-bliss-guidance-host` Draft PR #1]
(https://github.com/chrober/lms-bliss-guidance-host/pull/1).
This is a narrow compatibility patch layered on top of the older
vendored baseline documented above, **not** a complete synchronization
to the latest shared-host revision.

A review of `Runtime.pm` confirmed that the shared host also includes
newer structured-log-event dispatch behavior missing from the Lab's
existing vendor file. Automatically running `sync-guidance-host.ps1`
would import those unrelated logging changes. Do **not** sync all files
in this branch without a separate regression review of Lab formatter
compatibility. This test branch does not affect Lab `main` or release.
