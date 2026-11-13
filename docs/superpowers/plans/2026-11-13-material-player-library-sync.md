# Material Player Library Synchronization Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans; track steps below.

**Goal:** Provide independently opt-in Material/player-library synchronization and selected-library Christmas exceptions in Bliss Mixer Lab.

**Architecture:** Lab owns the synchronization script, a preserving managed Material bootstrap, and the opt-in settings. The Lyrion player library is authoritative; the DSTM request uses a frozen library identity for both candidate membership and its Christmas-filter decision. Upstream BlissMixer preferences and Material plugin sources remain untouched.

**Tech Stack:** Lyrion Perl, Material Vue/JavaScript, Perl and Node regression tests.

**Spec:** The approved conversation design: two disabled-by-default directional settings; a managed loader preserving existing customizations; explicit per-library exception selection.

## Global Constraints

- Never overwrite unrelated `custom.js` contents; safely handle the Pi's existing standalone prototype.
- Both directions are off by default. Changes require Save and fail visibly if loader installation fails.
- A server-to-Material update never triggers a write back; reconcile foreground clients after missed events and reconnects.
- Exceptions use virtual-library identities, are restricted to Lab DSTM, and never change upstream preferences or unrelated filters.
- Existing Lab log formats and unrelated working-tree changes are preserved.

## Review Focus

- Empty, existing, malformed, and unwritable Material customization: test preservation, idempotence, failure and disable behavior.
- Unset, removed, or renamed library and concurrent player switch: test frozen identity and fail-closed decisions.
- All four directional configurations and clients changing the same player: test event paths and feedback guards.
- Reload, sleep/reconnect and missed events: test bounded reconciliation, stale responses and hidden clients.
- Existing standalone prototype: identify it without deleting or duplicating unknown customizations; report conflicts.

### Task 1: Christmas policy

**Files:** `BlissMixerLab/CandidateLibrarySnapshot.pm`, `BlissMixerLab/Plugin.pm`, `BlissMixerLab/Settings.pm`, settings template, strings, and focused tests.

- [x] Write failing tests for exact selected library IDs, empty and unknown IDs, unchanged upstream setting, other filters and frozen library identity.
- [x] Implement explicit library selection and per-request filter override; add a separate explanatory log line.
- [x] Run focused tests and relevant existing DSTM contract tests.

### Task 2: Material bridge

**Files:** Lab-owned Material script and loader manager, plugin/settings integration, strings, tests.

- [x] Write focused tests for direction combinations, notification loss, reconnection and no feedback.
- [x] Implement Lab-owned script and a managed loader that preserves other customizations and detects conflicts.
- [x] Add disabled-by-default settings and explain global player scope, client reload and conflicting Material option.
- [x] Run Node/Perl regression tests including loader preservation and error handling.

### Task 3: Verify and document

- [x] Run repository validation, relevant regression tests and log-format checks.
- [x] Update Lab documentation with settings, migration, limitations and resource behavior.
- [ ] Verify integrated settings and behavior in real Material clients after an authorized deployment.
