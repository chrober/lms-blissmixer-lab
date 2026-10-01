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
