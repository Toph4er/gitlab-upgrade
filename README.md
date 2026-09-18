# GitLab Upgrade

Automated GitLab Docker upgrade script. Walks the required version path step by step, waiting for background migrations to complete between each step. The path can be given explicitly, or auto-detected from GitLab's canonical upgrade path and Docker Hub's published releases.

## Features

- **Automatic path detection** — `--automatic` detects the running version and builds the required path from GitLab's official `upgrade_path.yml` + Docker Hub tags (each stop resolved to the latest published patch)
- **Explicit upgrade paths** — specify any sequence: `18.11.2 => 18.11.4 => 19.0.1`
- **Check-only mode** — `--check` reports whether an update is available and exits with a stable code; never modifies anything
- **Dynamic migration polling** — waits for background migrations to finish instead of static timeouts
- **Major version detection** — automatically extends wait time for major version hops (PostgreSQL upgrades)
- **Version validation** — confirms the running version before and after each step
- **Robust network handling** — fetches are retried with diagnostics; `--debug` for full visibility
- **Community & Enterprise** — supports both CE and EE editions

## Requirements

- Bash 4+
- Docker, Docker Compose (V2)
- GitLab running as a Docker container
- For `--automatic` / `--check`: network access to `gitlab.com` (API) and `hub.docker.com`

## Quick start

```bash
# 1. Is there an update? (read-only, never modifies anything)
./gitlab-upgrade.sh --community --check

# 2. Upgrade: detect the path, confirm, execute
./gitlab-upgrade.sh --community --automatic

# 3. Same, unattended (no confirmation prompt)
./gitlab-upgrade.sh --community --automatic --yes

# Explicit path instead of auto-detection
./gitlab-upgrade.sh --community --path "18.11.4 => 19.0.1"

# Enterprise, custom container name
./gitlab-upgrade.sh --enterprise --path "17.11.4 => 17.11.7 => 18.2.8 => 19.0.1" --container-name my-gitlab
```

## Options

| Option | Description |
|---|---|
| `--community` | GitLab Community Edition (ce) |
| `--enterprise` | GitLab Enterprise Edition (ee) |
| `--path "A => B => C"` | Explicit upgrade path (current => intermediates => target) |
| `--automatic` | Auto-detect upgrade path from GitLab + Docker Hub |
| `--check` | Check for updates only (implies `--automatic`). Never modifies anything. Exit codes below |
| `--yes`, `-y` | Skip confirmation prompts |
| `--debug` | Verbose diagnostics: URLs, HTTP status, per-stop resolution (stderr) |
| `--container-name N` | Container name (default: `gitlab`) |
| `--compose-file F` | Compose file (default: `compose.yaml`, falls back to `docker-compose.yaml`/`.yml`) |

## Checking for updates

`--check` is the scripting-friendly mode: it detects the running version, determines whether a newer reachable release exists, and exits — without any confirmation prompt or changes.

```bash
./gitlab-upgrade.sh --community --check
echo "exit=$?"
```

| Exit code | Meaning |
|---|---|
| `0` | Up to date (nothing published at or above the running version) |
| `10` | Update available — the full upgrade path is printed |
| `1` | Error (version detection or path resolution failed) |

Example — update available:

```
[OK]    Update available: 18.11.0 => 19.2.6 => 19.4.0
[INFO]  Run without --check to perform this upgrade.
exit=10
```

Useful for cron jobs or sweeping multiple servers:

```bash
for host in host-a host-b; do
  ssh "$host" 'cd /path/to/gitlab && ./gitlab-upgrade.sh --community --check'
  echo "$host: exit=$?"
done
```

## How It Works

For each version in the upgrade path:

1. **Pull** the new Docker image
2. **Update** `compose.yaml` with the new image tag
3. **Restart** the container via `docker compose up -d`
4. **Wait** for the container to become healthy
5. **Poll** for background migrations to complete (10 min timeout for normal steps, 30 min for major version hops)
6. **Verify** the running version matches the target

## Automatic path detection

`--automatic` (and `--check`) resolve the path as follows:

1. **Detect the running version** — `gitlab-rake gitlab:env:info`, then image label, then the compose file, then `docker inspect`.
2. **Fetch GitLab's canonical stop sequence** — `config/upgrade_path.yml` from the `gitlab-org/gitlab` repository via the gitlab.com API.
3. **Resolve each stop** at or above the running version to the latest published image tag on Docker Hub (e.g. stop `19.2` → `19.2.6`).
4. **Extend past the last stop** — if newer releases are published after the final stop (e.g. `19.4.0` after the `19.2` stop, or a newer minor within the same major), they're appended so the path ends at the newest reachable release.
5. **Confirm** — the resolved path is printed and you're asked `y/N` before anything is pulled (skip with `--yes`, or avoid the prompt entirely with `--check`).

All network fetches retry 3× with a 3 s delay; on persistent failure the script reports the curl exit code or HTTP status + body snippet (full detail with `--debug`) and exits `1` — it never guesses a path.

Example (as of Sept 2026): from `18.11.0` → `18.11.0 => 19.2.6 => 19.4.0`.

## Migration detection

The script checks for pending background migrations using:

1. `gitlab-rake gitlab:background_migrations:list` (GitLab 18.9+) or `:status` (18.8 and earlier)
2. Fallback: direct PostgreSQL query on the `batched_background_migrations` table

## Generating manual paths

Use the [GitLab Upgrade Path Tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/) to determine the required intermediate versions for a manual `--path` upgrade.

## License

MIT — see [LICENSE](LICENSE)
