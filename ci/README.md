# CI: build & release pipeline

`/.github/workflows/build-release.yml` builds the map on a throwaway Hetzner
Cloud VM and publishes it as a GitHub Release, then deletes the VM.

## Flow

1. **provision** (GitHub-hosted runner) — asks the GitHub API for a runner
   registration token, then creates a Hetzner VM whose cloud-init
   (`ci/runner-userdata.sh`) installs the toolchain and registers the VM as an
   **ephemeral** self-hosted runner with a unique per-run label.
2. **build** (on the Hetzner VM) — runs `ci/build-map.sh`, which downloads the
   PBF(s), runs `preprocess-fuel-areas.sh`, splits, and runs mkgmap with the
   `Style - Default-Van` style → `out/gmapsupp.img`. The `.img` is uploaded as a
   GitHub Release asset (tag `map-YYYYMMDD-<run#>`).
3. **teardown** (always) — deletes the VM so a failed build never leaks a
   paid server.

## Triggers

- **Manual** (`Run workflow`): pick the `pbf_url` (default = Berlin, for cheap
  testing) and `server_type` (default `ccx33`). Set `pbf_url` to
  `https://download.geofabrik.de/europe/germany/germany-latest.osm.pbf` for the
  full Germany release.
- **Monthly** cron (1st of the month, 03:00 UTC) — rebuilds from fresh OSM.
  Uses the defaults (currently Berlin — change the default in the workflow when
  ready to release Germany automatically).

## Required repo secrets

| Secret | What | Notes |
|---|---|---|
| `HETZNER_TOKEN` | Hetzner Cloud API token | Project → Security → API tokens, **Read & Write**. |
| `GH_RUNNER_PAT` | Fine-grained PAT on this repo | Permissions: **Administration: Read and write** (needed to register a self-hosted runner — the built-in `GITHUB_TOKEN` can't). |
| `HETZNER_SSH_PUBLIC_KEY` | *(optional)* SSH public key | Attached to the VM for debugging; omit to skip. |

## Cost

`ccx33` is ~€0.10/hr, billed by the hour; a Berlin build is a few minutes and a
Germany build ~15–20 min, so a run costs a few cents. The VM is always deleted
in `teardown`.

## Local build (no CI)

`ci/build-map.sh` also runs locally:

```bash
MEM=24g ci/build-map.sh https://download.geofabrik.de/europe/germany/berlin-latest.osm.pbf
# -> out/gmapsupp.img
```

Needs `openjdk`, `osmium-tool`, `wget`, `unzip`, `python3`.
