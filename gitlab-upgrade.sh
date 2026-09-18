#!/usr/bin/env bash
#
# gitlab-upgrade.sh — Automated GitLab Docker upgrade through an explicit version path.
#
# Usage:
#   gitlab-upgrade.sh --community --path "18.11.2 => 18.11.4 => 19.0.1"
#   gitlab-upgrade.sh --enterprise --path "18.11.2 => 18.11.4 => 19.0.1"
#   gitlab-upgrade.sh --community --path "18.11.2 => 19.0.1" --container-name my-gitlab
#
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# ── Defaults ─────────────────────────────────────────────────────────────────
EDITION=""          # "ce" or "ee"
UPGRADE_PATH=""     # raw path string
CONTAINER_NAME="gitlab"
COMPOSE_FILE="compose.yaml"
AUTOMATIC=false     # auto-detect upgrade path from GitLab + Docker Hub
ASSUME_YES=false    # skip confirmation prompts
DEBUG=false         # verbose diagnostics (URLs, HTTP status, per-stop resolution)
CHECK=false         # check for updates only (implies --automatic); exit 0/10
HEALTH_CHECK_INTERVAL=5         # seconds between health polls
HEALTH_CHECK_TIMEOUT=600        # max seconds to wait for healthy (10 min)
MIGRATION_CHECK_INTERVAL=10     # seconds between migration status polls
MIGRATION_TIMEOUT_NORMAL=600    # max seconds for normal upgrade migrations (10 min)
MIGRATION_TIMEOUT_MAJOR=1800    # max seconds for major-version migrations (30 min)
UPGRADE_API_URL="https://gitlab.com/api/v4/projects/gitlab-org%2Fgitlab/repository/files/config%2Fupgrade_path.yml/raw?ref=master"
DOCKER_HUB_API="https://hub.docker.com/v2/repositories/gitlab"

# ── Helpers ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

die() { log_error "$@"; exit 1; }

# Print a debug line to stderr, but only when --debug is set.
dbg() { [ "$DEBUG" = "true" ] || return 0; echo -e "${GRAY}[DEBUG]${NC} $*" >&2; }

# Check if background migrations are still running.
# Returns 0 if all done, 1 if migrations remain, 2 if check failed.
# Prints a short progress line to stdout on success.
check_background_migrations() {
    local version="$1"
    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)

    # Determine the right rake task based on GitLab version
    # 18.9+ uses :list, earlier uses :status
    local rake_task="gitlab:background_migrations:status"
    if [ "$major" -gt 18 ] 2>/dev/null || { [ "$major" -eq 18 ] && [ "$minor" -ge 9 ] 2>/dev/null; }; then
        rake_task="gitlab:background_migrations:list"
    fi

    # Try the rake task first
    local output
    output=$(timeout 30 docker exec "$CONTAINER_NAME" gitlab-rake "$rake_task" 2>/dev/null) || true

    if [ -n "$output" ]; then
        # Look for rows with active/queued/finalizing status
        # The :list output is a table; :status output lists migrations
        local pending
        pending=$(echo "$output" | grep -iE '(active|queued|finalizing)' | grep -v '^$' | head -5)

        if [ -n "$pending" ]; then
            # Count pending migrations
            local count
            count=$(echo "$pending" | wc -l)
            # Try to extract estimated time remaining from the output
            local eta
            eta=$(echo "$output" | grep -oP 'estimated time remaining:\s*\K[0-9]+ minutes' | head -1)
            if [ -n "$eta" ]; then
                echo "  ${count} migration(s) in progress (${eta})"
            else
                echo "  ${count} migration(s) in progress"
            fi
            return 1
        else
            echo "  All background migrations complete"
            return 0
        fi
    fi

    # Fallback: direct DB query
    # status codes: 0=queued, 1=active, 2=paused, 3=finished, 4=failed, 5=cancelled, 6=finalized
    local db_result
    db_result=$(timeout 10 docker exec "$CONTAINER_NAME" gitlab-psql -t -c \
        "SELECT COUNT(*) FROM batched_background_migrations WHERE status NOT IN (3, 6);" 2>/dev/null) || true

    if [ -n "$db_result" ]; then
        local count
        count=$(echo "$db_result" | tr -d '[:space:]')
        if [ "$count" -gt 0 ] 2>/dev/null; then
            echo "  ${count} migration(s) in progress (DB check)"
            return 1
        else
            echo "  All background migrations complete (DB check)"
            return 0
        fi
    fi

    # Both methods failed — we can't determine status
    echo "  Unable to check migration status"
    return 2
}

# Wait for background migrations to finish, with a live progress display
wait_for_background_migrations() {
    local target_version=$1
    local timeout=$2
    local label="${3:-Background migrations}"
    local elapsed=0

    log_info "Polling for background migrations (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local status_line
        status_line=$(check_background_migrations "$target_version")
        local check_result=$?

        case $check_result in
            0)
                # All done
                printf "\r  %s ... %s\n" "$label" "$status_line"
                log_ok "Background migrations complete"
                return 0
                ;;
            1)
                # Still in progress
                printf "\r  %s ... %s   " "$label" "$status_line"
                ;;
            2)
                # Check failed — warn but keep polling
                printf "\r  %s ... %s   " "$label" "$status_line"
                ;;
        esac

        sleep "$MIGRATION_CHECK_INTERVAL"
        elapsed=$((elapsed + MIGRATION_CHECK_INTERVAL))
    done

    printf "\r  %s ... timeout after %ds\n" "$label" "$timeout"
    log_warn "Migration check timed out. Continuing anyway — verify manually."
    return 0  # Don't abort, just warn
}

# Check if a string looks like a semver version (not a sha256 hash)
looks_like_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+ ]]
}

# Detect the running GitLab version using multiple methods
get_current_version() {
    local version=""

    # Method 1: Try gitlab-rake gitlab:env:info (most reliable)
    # Use a timeout since this can be slow on first run or during upgrades
    version=$(timeout 30 docker exec "$CONTAINER_NAME" gitlab-rake gitlab:env:info 2>/dev/null \
        | sed -n '/GitLab information/,/^$/p' \
        | grep -E 'Version:' \
        | head -1 \
        | awk '{print $2}')

    if [ -n "$version" ] && looks_like_version "$version"; then
        echo "$version"
        return 0
    fi

    # Method 2: Read from the image label if the container is running
    version=$(docker inspect --format='{{index .Config.Labels "org.label-schema.version"}}' "$CONTAINER_NAME" 2>/dev/null)
    if [ -n "$version" ] && [ "$version" != "<no value>" ] && looks_like_version "$version"; then
        echo "$version"
        return 0
    fi

    # Method 3: Parse the image tag from compose.yaml (our source of truth)
    if [ -f "$COMPOSE_FILE" ]; then
        version=$(grep -E '^\s*image:\s*["\x27]?gitlab/gitlab-' "$COMPOSE_FILE" \
            | head -1 \
            | sed -E "s/.*gitlab\/gitlab-[a-z]+:([0-9]+\.[0-9]+\.[0-9]+).*/\1/")
        if [ -n "$version" ] && looks_like_version "$version"; then
            echo "$version"
            return 0
        fi
    fi

    # Method 4: Check the running image tag from docker inspect
    # Guard against sha256 digests which docker inspect returns for the Image field
    version=$(docker inspect "$CONTAINER_NAME" 2>/dev/null \
        | grep -oP '"Image":\s*"[^"]*:\K[^"]+' | head -1 | sed 's/-\{0,1\}\(ce\|ee\)\.0$//')
    if [ -n "$version" ] && looks_like_version "$version"; then
        echo "$version"
        return 0
    fi

    return 1
}

# ── Automatic upgrade path detection ─────────────────────────────────────────
# Fetches the canonical upgrade_path.yml from GitLab's repo and resolves each
# major.minor stop to the latest available Docker image tag.

# http_get LABEL URL
# Fetches URL, writes the response body to stdout.
# On failure, logs the reason (curl error / HTTP status) and returns non-zero.
# Transient failures (network errors, non-2xx) are retried up to 3 times.
http_get() {
    local label="$1" url="$2"
    local tmp http_code rc=0 detail attempt=1
    local max_attempts=3
    while [ $attempt -le $max_attempts ]; do
        rc=0
        tmp=$(mktemp) || return 1
        http_code=$(curl -sSL --max-time 15 -o "$tmp" -w '%{http_code}' "$url" 2>"${tmp}.err") || rc=$?
        if [ $rc -eq 0 ] && [ "${http_code:0:1}" = "2" ]; then
            dbg "GET ${url} -> HTTP ${http_code}, $(wc -c < "$tmp") bytes (attempt ${attempt})"
            cat "$tmp"
            rm -f "$tmp" "${tmp}.err"
            return 0
        fi
        if [ $rc -ne 0 ]; then
            local curl_err
            curl_err=$(head -c 200 "${tmp}.err" 2>/dev/null | tail -1)
            detail="curl exit ${rc}${curl_err:+ — ${curl_err}}"
        else
            local snippet
            snippet=$(head -c 200 "$tmp" 2>/dev/null | tr -d '\n')
            detail="HTTP ${http_code}${snippet:+ — ${snippet}}"
        fi
        rm -f "$tmp" "${tmp}.err"
        if [ $attempt -lt $max_attempts ]; then
            log_warn "Fetch of ${label} failed (${detail}); retrying in 3s (attempt ${attempt}/${max_attempts})" >&2
            sleep 3
            attempt=$((attempt + 1))
            continue
        fi
        log_warn "Failed to fetch ${label}: ${detail}" >&2
        dbg "URL: ${url}"
        if [ $rc -ne 0 ]; then
            return $rc
        fi
        return 1
    done
}

# Fetch and parse upgrade_path.yml from GitLab API
# Outputs lines like "18.11" "19.2" etc.
fetch_upgrade_stops() {
    local yaml
    yaml=$(http_get "upgrade_path.yml (gitlab.com API)" "$UPGRADE_API_URL") || return 1

    # Parse YAML: extract major.minor pairs
    echo "$yaml" | awk '
        /^- major:/ { major = $3 }
        /minor:/    { printf "%s.%s\n", major, $2 }
    '
}

# Query Docker Hub for the latest patch version of a major.minor series
# Returns "18.11.4" or empty string if no tags found
latest_patch_for() {
    local major_minor="$1"
    local repo="gitlab-ce"
    [ "$EDITION" = "ee" ] && repo="gitlab-ee"

    local url="${DOCKER_HUB_API}/${repo}/tags?name=${major_minor}."
    local tags
    tags=$(http_get "Docker Hub tags (name=${major_minor}.)" "$url") || return 1

    echo "$tags" | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
if data.get('results'):
    name = data['results'][0]['name']
    m = re.match(r'(\d+\.\d+\.\d+)', name)
    if m: print(m.group(1))
" 2>/dev/null || true
}

# Get the latest released version for a given major version from Docker Hub
# Returns the highest major.minor.patch available
latest_for_major() {
    local major="$1"
    local repo="gitlab-ce"
    [ "$EDITION" = "ee" ] && repo="gitlab-ee"

    # Get all tags starting with this major version
    local url="${DOCKER_HUB_API}/${repo}/tags?name=${major}.&page_size=100"
    local tags
    tags=$(http_get "Docker Hub tags (name=${major}.)" "$url") || return 1

    echo "$tags" | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
best = None
for t in data.get('results', []):
    m = re.match(r'(\d+\.\d+\.\d+)', t['name'])
    if m:
        v = tuple(int(x) for x in m.group(1).split('.'))
        if best is None or v > best:
            best = v
if best:
    print(f'{best[0]}.{best[1]}.{best[2]}')
" 2>/dev/null || true
}

# Build the automatic upgrade path from the current version.
# Exit codes: 0 = path built (printed), 3 = up to date (nothing published
# at or above current), 1 = error.
build_automatic_path() {
    local current="$1"
    local current_major current_minor
    current_major=$(echo "$current" | cut -d. -f1)
    current_minor=$(echo "$current" | cut -d. -f2)

    dbg "Current: ${current} (major=${current_major}, minor=${current_minor})"
    local stops
    stops=$(fetch_upgrade_stops) || die "Cannot build automatic path: failed to fetch upgrade data"
    dbg "Required upgrade stops: $(echo "$stops" | tr '\n' ' ')"

    local path=()
    local found_current=false
    local last_resolved_major="$current_major"
    local last_resolved_minor="$current_minor"

    # Resolve each required stop >= current version
    while IFS= read -r stop; do
        local s_major s_minor
        s_major=$(echo "$stop" | cut -d. -f1)
        s_minor=$(echo "$stop" | cut -d. -f2)

        # Skip stops before current version
        if [ "$s_major" -lt "$current_major" ] 2>/dev/null || \
           { [ "$s_major" -eq "$current_major" ] && [ "$s_minor" -lt "$current_minor" ] 2>/dev/null; }; then
            continue
        fi

        found_current=true

        # Resolve to latest patch version
        local resolved
        resolved=$(latest_patch_for "$stop") || resolved=""
        dbg "  stop ${stop} -> ${resolved:-(no published image)}"

        if [ -n "$resolved" ]; then
            path+=("$resolved")
            last_resolved_major="$s_major"
            last_resolved_minor="$s_minor"
        fi
    done <<< "$stops"

    if [ "$found_current" = false ]; then
        dbg "Current is newer than any known upgrade stop — treating as up to date"
        return 3
    fi

    # Check for published releases after the last resolved stop that aren't
    # stops themselves (e.g., 19.4 is newer than the 19.2 stop; 19.0.1 sits
    # between the 18.11 stop and the 19.2 stop). Check both the last-resolved
    # major (newer minors) and the next major (first release of a new series).
    local candidate c_major c_minor
    for check_major in "$last_resolved_major" "$((last_resolved_major + 1))"; do
        candidate=$(latest_for_major "$check_major") || candidate=""
        dbg "  post-stop check (major ${check_major}) -> ${candidate:-none}"
        [ -z "$candidate" ] && continue
        c_major=$(echo "$candidate" | cut -d. -f1)
        c_minor=$(echo "$candidate" | cut -d. -f2)
        # Only add if strictly newer than the last resolved stop
        if [ "$c_major" -lt "$last_resolved_major" ] || \
           { [ "$c_major" -eq "$last_resolved_major" ] && [ "$c_minor" -lt "$last_resolved_minor" ]; }; then
            continue
        fi
        # Skip if already in the path
        local already_have=false
        for v in "${path[@]}"; do
            local vm=$(echo "$v" | cut -d. -f1)
            local vn=$(echo "$v" | cut -d. -f2)
            if [ "$vm" = "$c_major" ] && [ "$vn" = "$c_minor" ]; then
                already_have=true
                break
            fi
        done
        if [ "$already_have" = false ]; then
            path+=("$candidate")
        fi
    done

    if [ "${#path[@]}" -eq 0 ]; then
        # Stops >= current exist but none has a published image yet:
        # we're on the latest reachable release. Not an error.
        dbg "No published image at or above ${current} — up to date"
        return 3
    fi

    # If the current version's major.minor matches the first path element,
    # replace it with the current version (we're already on that minor)
    local first="${path[0]}"
    local first_major first_minor
    first_major=$(echo "$first" | cut -d. -f1)
    first_minor=$(echo "$first" | cut -d. -f2)
    if [ "$first_major" = "$current_major" ] && [ "$first_minor" = "$current_minor" ]; then
        path[0]="$current"
        # If current == latest patch and there's only one element, we're done
        if [ "$current" = "$first" ] && [ "${#path[@]}" -le 1 ]; then
            return 3
        fi
        # If current == latest patch, skip this element (nothing to upgrade for this minor)
        if [ "$current" = "$first" ]; then
            path=("${path[@]:1}")
        fi
    fi

    if [ "${#path[@]}" -eq 0 ]; then
        return 3
    fi

    dbg "Resolved path: ${path[*]}"
    echo "${path[*]}"
}

# ── Argument parsing ─────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
Usage:
  gitlab-upgrade.sh --community --path "18.11.2 => 18.11.4 => 19.0.1"
  gitlab-upgrade.sh --enterprise --path "18.11.2 => 18.11.4 => 19.0.1"
  gitlab-upgrade.sh --community --automatic
  gitlab-upgrade.sh --community --automatic --yes
  gitlab-upgrade.sh --community --automatic --debug
  gitlab-upgrade.sh --community --check        # report only, never modifies

Options:
  --community        GitLab Community Edition (ce)
  --enterprise       GitLab Enterprise Edition (ee)
  --path "A => B => C"  Upgrade path (current => intermediates => target)
  --automatic        Auto-detect upgrade path from GitLab + Docker Hub
  --yes              Skip confirmation prompts (use with --automatic)
  --debug            Verbose diagnostics: URLs, HTTP status, per-stop resolution
  --check            Check for updates only (implies --automatic). Never
                     modifies anything. Exit codes: 0 = up to date,
                     10 = update available, 1 = error
  --container-name N     Container name (default: gitlab)
  --compose-file F       Compose file (default: compose.yaml)
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --community)
            [ -n "$EDITION" ] && die "Cannot specify both --community and --enterprise"
            EDITION="ce"
            shift
            ;;
        --enterprise)
            [ -n "$EDITION" ] && die "Cannot specify both --community and --enterprise"
            EDITION="ee"
            shift
            ;;
        --path)
            [ $# -lt 2 ] && die "--path requires an argument"
            UPGRADE_PATH="$2"
            shift 2
            ;;
        --automatic)
            AUTOMATIC=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --check)
            CHECK=true
            shift
            ;;
        --yes|-y)
            ASSUME_YES=true
            shift
            ;;
        --container-name)
            [ $# -lt 2 ] && die "--container-name requires an argument"
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --compose-file)
            [ $# -lt 2 ] && die "--compose-file requires an argument"
            COMPOSE_FILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# --check implies automatic detection and excludes --path
if [ "$CHECK" = true ]; then
    [ -n "$UPGRADE_PATH" ] && die "--check cannot be combined with --path"
    AUTOMATIC=true
fi

# ── Validate required arguments ──────────────────────────────────────────────
[ -z "$EDITION" ] && die "Must specify --community or --enterprise"
[ "$AUTOMATIC" = false ] && [ -z "$UPGRADE_PATH" ] && die "Must specify --path or --automatic"
[ "$AUTOMATIC" = true ] && [ -n "$UPGRADE_PATH" ] && die "Cannot specify both --path and --automatic"

# ── Resolve the upgrade path ─────────────────────────────────────────────────
if [ "$AUTOMATIC" = true ]; then
    log_step "Detecting current GitLab version..."

    # We need the running version before we can build the path
    # Validate compose.yaml exists first (needed by get_current_version method 3)
    if [ ! -f "$COMPOSE_FILE" ]; then
        if [ -f "docker-compose.yaml" ]; then
            COMPOSE_FILE="docker-compose.yaml"
            log_warn "compose.yaml not found, using docker-compose.yaml"
        elif [ -f "docker-compose.yml" ]; then
            COMPOSE_FILE="docker-compose.yml"
            log_warn "compose.yaml not found, using docker-compose.yml"
        else
            die "No compose file found (tried compose.yaml, docker-compose.yaml, docker-compose.yml)"
        fi
    fi

    RUNNING_VERSION=$(get_current_version) || true
    if [ -z "$RUNNING_VERSION" ]; then
        die "Cannot auto-detect running version. Specify --path manually."
    fi
    log_ok "Detected running version: ${RUNNING_VERSION}"

    log_step "Building upgrade path from ${RUNNING_VERSION}..."
    build_rc=0
    AUTO_PATH=$(build_automatic_path "$RUNNING_VERSION") || build_rc=$?
    if [ $build_rc -eq 3 ]; then
        log_ok "You're on ${RUNNING_VERSION} — the latest reachable GitLab ${EDITION^^} release."
        log_ok "Nothing to upgrade; a newer stop will appear here once it's published."
        exit 0
    fi
    if [ $build_rc -ne 0 ]; then
        log_warn "Automatic path detection failed. Specify --path manually."
        exit 1
    fi

    # Format as "current => step1 => step2 => ..."
    UPGRADE_PATH="${RUNNING_VERSION} => ${AUTO_PATH// / => }"

    # Check-only mode: report and stop without modifying anything
    if [ "$CHECK" = true ]; then
        log_ok "Update available: ${UPGRADE_PATH}"
        log_info "Run without --check to perform this upgrade."
        exit 10
    fi

    log_info "Resolved upgrade path: ${UPGRADE_PATH}"
    echo ""

    # Confirm with user (unless --yes)
    if [ "$ASSUME_YES" = false ]; then
        echo -n "Proceed with this upgrade path? [y/N] "
        read -r confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user"
        log_ok "Confirmed"
        echo ""
    fi

    CURRENT_VERSION="$RUNNING_VERSION"
    # Parse the auto-resolved path (space-separated) into array
    IFS=' ' read -r -a TARGET_VERSIONS <<< "$AUTO_PATH"
else
    # ── Validate compose.yaml exists ─────────────────────────────────────────
    if [ ! -f "$COMPOSE_FILE" ]; then
        # Also check docker-compose.yaml as a fallback
        if [ -f "docker-compose.yaml" ]; then
            COMPOSE_FILE="docker-compose.yaml"
            log_warn "compose.yaml not found, using docker-compose.yaml"
        elif [ -f "docker-compose.yml" ]; then
            COMPOSE_FILE="docker-compose.yml"
            log_warn "compose.yaml not found, using docker-compose.yml"
        else
            die "No compose file found (tried compose.yaml, docker-compose.yaml, docker-compose.yml)"
        fi
    fi

    # ── Parse the upgrade path ───────────────────────────────────────────────
    # Split on " => " separator, trim whitespace, collect into array
    versions=()
    remaining="$UPGRADE_PATH"
    while [[ "$remaining" =~ ^[[:space:]]*([^[:space:]]+) ]]; do
        versions+=("${BASH_REMATCH[1]}")
        remaining="${remaining#*${BASH_REMATCH[1]}}"
        # Remove " => " separator if present
        remaining="${remaining#*=>}"
    done

    [ "${#versions[@]}" -lt 2 ] && die "Upgrade path must contain at least two versions (current => target)"

    CURRENT_VERSION="${versions[0]}"
    TARGET_VERSIONS=("${versions[@]:1}")
fi

log_info "Edition:          GitLab ${EDITION^^}"
log_info "Container name:   ${CONTAINER_NAME}"
log_info "Compose file:     ${COMPOSE_FILE}"
log_info "Current version:  ${CURRENT_VERSION}"
log_info "Upgrade path:     ${CURRENT_VERSION} => $(IFS=' => '; echo "${TARGET_VERSIONS[*]}")"
echo ""

# ── Validate current version (skip if --automatic already confirmed) ─────────
if [ "$AUTOMATIC" = false ]; then
    log_step "Validating current GitLab version..."

    RUNNING_VERSION=$(get_current_version) || true

    if [ -n "$RUNNING_VERSION" ]; then
        if [ "$RUNNING_VERSION" != "$CURRENT_VERSION" ]; then
            die "Version mismatch: expected ${CURRENT_VERSION} but running ${RUNNING_VERSION}"
        fi
        log_ok "Current version confirmed: ${RUNNING_VERSION}"
    else
        log_warn "Could not auto-detect running version. Proceeding with user-provided version: ${CURRENT_VERSION}"
        log_warn "If the version is wrong, the upgrade may fail."
    fi
fi

# ── Extract major version ────────────────────────────────────────────────────
major_version() {
    echo "$1" | cut -d. -f1
}

# ── Docker image helpers ─────────────────────────────────────────────────────
image_tag() {
    # Build the full image tag: gitlab/gitlab-ce:18.11.4-ce.0
    echo "gitlab/gitlab-${EDITION}:${1}-${EDITION}.0"
}

# ── Wait for container to be healthy ─────────────────────────────────────────
wait_for_healthy() {
    local container=$1
    local timeout=$2
    local interval=$3
    local elapsed=0

    log_info "Waiting for container '${container}' to become healthy (timeout: ${timeout}s)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")

        case "$health" in
            healthy)
                log_ok "Container '${container}' is healthy"
                return 0
                ;;
            unhealthy)
                die "Container '${container}' is unhealthy"
                ;;
            starting)
                # Keep waiting
                ;;
            "")
                # Healthcheck not configured yet or container restarting
                # Check if container is at least running
                local state
                state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
                if [ "$state" != "running" ]; then
                    die "Container '${container}' is not running (state: ${state})"
                fi
                ;;
            unknown)
                # Container might not exist yet
                die "Container '${container}' not found"
                ;;
        esac

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    die "Timeout waiting for container '${container}' to become healthy (${timeout}s elapsed)"
}

# ── Update compose.yaml image line ───────────────────────────────────────────
update_compose_image() {
    local new_image=$1
    local file=$COMPOSE_FILE

    # Find the image line for the gitlab service
    # Match patterns like:
    #   image: gitlab/gitlab-ce:18.11.2-ce.0
    #   image:  gitlab/gitlab-ce:18.11.2-ce.0
    #   image: "gitlab/gitlab-ce:18.11.2-ce.0"
    if grep -qE '^\s*image:\s*["\x27]?gitlab/gitlab-' "$file"; then
        # Use sed to replace the image line (handles optional quotes)
        sed -i -E "s|^(\s*image:\s*[\"']?)gitlab/gitlab-[^\"' ]+[\"']?|\1${new_image}|g" "$file"
        log_ok "Updated ${file} image to ${new_image}"
    else
        die "Could not find 'image: gitlab/gitlab-*' line in ${file}"
    fi
}

# ── Main upgrade loop ────────────────────────────────────────────────────────
echo ""
log_step "Beginning upgrade sequence"
echo ""

PREV_MAJOR=""

for TARGET in "${TARGET_VERSIONS[@]}"; do
    TARGET_MAJOR=$(major_version "$TARGET")
    IMAGE=$(image_tag "$TARGET")

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_step "Upgrading to GitLab ${TARGET} (${EDITION})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 1. Pull the image
    log_info "Pulling ${IMAGE}..."
    if docker pull "$IMAGE"; then
        log_ok "Image pulled successfully"
    else
        die "Failed to pull ${IMAGE}"
    fi

    # 2. Update compose.yaml
    log_info "Updating ${COMPOSE_FILE}..."
    update_compose_image "$IMAGE"

    # 3. Restart the container
    log_info "Restarting container with new image..."
    if docker compose -f "$COMPOSE_FILE" up -d "$CONTAINER_NAME"; then
        log_ok "Container restarted"
    else
        die "Failed to restart container"
    fi

    # 4. Wait for healthy
    wait_for_healthy "$CONTAINER_NAME" "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_INTERVAL"

    # 5. Wait for background migrations to complete
    IS_MAJOR_HOP=false
    if [ -n "$PREV_MAJOR" ] && [ "$TARGET_MAJOR" != "$PREV_MAJOR" ]; then
        IS_MAJOR_HOP=true
        log_warn "Major version change detected (${PREV_MAJOR} → ${TARGET_MAJOR})"
    fi

    if [ "$IS_MAJOR_HOP" = true ]; then
        wait_for_background_migrations "$TARGET" "$MIGRATION_TIMEOUT_MAJOR" "Major upgrade migrations"
    else
        wait_for_background_migrations "$TARGET" "$MIGRATION_TIMEOUT_NORMAL" "Post-install migrations"
    fi

    PREV_MAJOR="$TARGET_MAJOR"

    # 7. Verify the upgrade took effect
    log_info "Verifying running version..."
    VERIFIED=$(get_current_version) || true
    if [ -n "$VERIFIED" ]; then
        if [ "$VERIFIED" = "$TARGET" ]; then
            log_ok "Version ${TARGET} confirmed"
        else
            log_warn "Expected version ${TARGET} but detected ${VERIFIED}"
            log_warn "Continuing — manual verification recommended"
        fi
    else
        log_warn "Could not verify version after upgrade to ${TARGET}"
    fi

    echo ""
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_ok "Upgrade complete!"
log_info "GitLab is now running version ${TARGET_VERSIONS[-1]} (${EDITION})"
log_info "Container: ${CONTAINER_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
