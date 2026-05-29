# GitLab Upgrade

Automated GitLab Docker upgrade script that follows an explicit version path, waiting for background migrations to complete between each step.

## Features

- **Explicit upgrade paths** — specify any sequence: `17.11.4 => 17.11.7 => 18.2.8 => 19.0.1`
- **Dynamic migration polling** — waits for background migrations to finish instead of static timeouts
- **Major version detection** — automatically extends wait time for major version hops (PostgreSQL upgrades)
- **Version validation** — confirms running version before and after each step
- **Community & Enterprise** — supports both CE and EE editions

## Requirements

- Bash 4+
- Docker
- Docker Compose (V2)
- GitLab running as a Docker container

## Usage

```bash
# Community Edition
./gitlab-upgrade.sh --community --path "18.11.4 => 19.0.1"

# Enterprise Edition with custom container name
./gitlab-upgrade.sh --enterprise --path "17.11.4 => 17.11.7 => 18.2.8 => 18.5.7 => 18.8.10 => 18.11.4 => 19.0.1" --container-name my-gitlab

# With custom compose file
./gitlab-upgrade.sh --community --path "18.11.4 => 19.0.1" --compose-file docker-compose.yaml
```

## Options

| Option | Description |
|---|---|
| `--community` | GitLab Community Edition (ce) |
| `--enterprise` | GitLab Enterprise Edition (ee) |
| `--path "A => B => C"` | Upgrade path (current => intermediates => target) |
| `--container-name N` | Container name (default: `gitlab`) |
| `--compose-file F` | Compose file (default: `compose.yaml`) |

## How It Works

For each version in the upgrade path:

1. **Pull** the new Docker image
2. **Update** `compose.yaml` with the new image tag
3. **Restart** the container via `docker compose up -d`
4. **Wait** for the container to become healthy
5. **Poll** for background migrations to complete (10 min timeout for normal steps, 30 min for major version hops)
6. **Verify** the running version matches the target

## Migration Detection

The script checks for pending background migrations using:

1. `gitlab-rake gitlab:background_migrations:list` (GitLab 18.9+) or `:status` (18.8 and earlier)
2. Fallback: direct PostgreSQL query on `batched_background_migrations` table

## Generating Upgrade Paths

Use the [GitLab Upgrade Path Tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/) to determine the required intermediate versions for your upgrade.

## License

MIT — see [LICENSE](LICENSE)
