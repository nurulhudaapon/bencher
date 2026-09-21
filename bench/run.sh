#!/usr/bin/env bash
# Docker-only bench orchestrator (no host Zig required).
#
# Usage:
#   bash bench/run.sh [framework ...]     # run (uses committed compose.yml)
#   bash bench/run.sh --write-compose     # regenerate compose.yml after adding frameworks
#
# Env:
#   BENCH_SKIP_BUILD=1   never rebuild images
#   BENCH_FORCE_BUILD=1  always rebuild
#   BENCH_PLATFORM=...   e.g. linux-x86_64 / linux-aarch64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FRAMEWORKS_DIR="$REPO_ROOT/frameworks"
RESULTS_DIR="$REPO_ROOT/app"
COMPOSE_PATH="$SCRIPT_DIR/compose.yml"
COMPOSE=(docker compose -f "$COMPOSE_PATH")

WRITE_COMPOSE=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--write-compose" ]; then
    WRITE_COMPOSE=true
  else
    ARGS+=("$arg")
  fi
done

is_disabled() {
  local zon="$1"
  [ -f "$zon" ] || return 1
  awk '
    /\.meta/ { in_meta=1 }
    in_meta && /\.disabled[[:space:]]*=[[:space:]]*true/ { found=1; exit }
    END { exit !found }
  ' "$zon"
}

discover_frameworks() {
  local fw
  for zon in "$FRAMEWORKS_DIR"/*/build.zig.zon; do
    [ -f "$zon" ] || continue
    fw="$(basename "$(dirname "$zon")")"
    [ "$fw" = "shared" ] && continue
    if is_disabled "$zon"; then
      echo "skip framework $fw (disabled in build.zig.zon .meta)" >&2
      continue
    fi
    echo "$fw"
  done | sort
}

# Framework service names from committed compose.yml (excludes bencher).
compose_frameworks() {
  awk '
    /^services:/ { in_svc=1; next }
    in_svc && /^[^[:space:]#]/ { in_svc=0 }
    in_svc && /^  [A-Za-z0-9_-]+:/ {
      name = $1
      sub(/:$/, "", name)
      if (name != "bencher") print name
    }
  ' "$COMPOSE_PATH"
}

is_privileged() {
  local fw="$1"
  [ -f "$FRAMEWORKS_DIR/$fw/privileged" ] && return 0
  local zon="$FRAMEWORKS_DIR/$fw/build.zig.zon"
  [ -f "$zon" ] || return 1
  awk '
    /\.meta/ { in_meta=1 }
    in_meta && /\.privileged[[:space:]]*=[[:space:]]*true/ { found=1; exit }
    END { exit !found }
  ' "$zon"
}

binary_name() {
  echo "bench_$(echo "$1" | tr '-' '_')"
}

write_compose() {
  local fw binary
  local discovered=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    discovered+=("$line")
  done <<EOF
$(discover_frameworks)
EOF

  if [ ${#discovered[@]} -eq 0 ]; then
    echo "error: no frameworks discovered under frameworks/" >&2
    exit 1
  fi

  {
    cat <<'EOF'
# Regenerate with: bash bench/run.sh --write-compose
name: zig_web_bench

x-framework: &framework
  deploy:
    resources:
      limits:
        cpus: "2"
        memory: 2G
  networks:
    - bench-net

x-healthcheck: &healthcheck
  test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8081/httpz"]
  interval: 1s
  timeout: 2s
  retries: 15
  start_period: 5s

services:
EOF

    for fw in "${discovered[@]}"; do
      binary="$(binary_name "$fw")"
      echo "  $fw:"
      echo "    <<: *framework"
      echo "    image: zig_web_bench-$fw"
      echo "    build:"
      echo "      context: .."
      if [ -f "$FRAMEWORKS_DIR/$fw/Dockerfile" ]; then
        echo "      dockerfile: frameworks/$fw/Dockerfile"
      else
        echo "      dockerfile: frameworks/Dockerfile"
        echo "      args:"
        echo "        FRAMEWORK: $fw"
        echo "        BINARY: $binary"
      fi
      if is_privileged "$fw"; then
        echo "    privileged: true"
      fi
      echo "    healthcheck: *healthcheck"
      echo ""
    done

    cat <<'EOF'
  bencher:
    image: zig_web_bench-bencher
    build:
      context: ..
      dockerfile: bench/docker/Dockerfile
      args:
        ZIG_VER: "0.16.0"
    # zio/zrk needs io_uring (Docker Desktop / OrbStack)
    privileged: true
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
    environment:
      BENCH_FRAMEWORKS: ${BENCH_FRAMEWORKS:-}
      BENCH_SCENARIOS: ${BENCH_SCENARIOS:-}
      BENCH_PLATFORM: ${BENCH_PLATFORM:-}
    volumes:
      - ../app:/out
    networks:
      - bench-net

networks:
  bench-net:
    driver: bridge
EOF
  } > "$COMPOSE_PATH"

  echo "wrote $COMPOSE_PATH (${#discovered[@]} frameworks: ${discovered[*]})"
}

if [ "$WRITE_COMPOSE" = true ]; then
  write_compose
  if [ ${#ARGS[@]} -eq 0 ]; then
    exit 0
  fi
fi

if [ ! -f "$COMPOSE_PATH" ]; then
  echo "error: $COMPOSE_PATH missing — run: bash bench/run.sh --write-compose" >&2
  exit 1
fi

ALL_FRAMEWORKS=()
while IFS= read -r fw; do
  [ -n "$fw" ] || continue
  ALL_FRAMEWORKS+=("$fw")
done <<EOF
$(compose_frameworks)
EOF

if [ ${#ALL_FRAMEWORKS[@]} -eq 0 ]; then
  echo "error: no framework services in $COMPOSE_PATH" >&2
  exit 1
fi

if [ ${#ARGS[@]} -gt 0 ]; then
  FRAMEWORKS=("${ARGS[@]}")
  for fw in "${FRAMEWORKS[@]}"; do
    found=false
    for known in "${ALL_FRAMEWORKS[@]}"; do
      if [ "$fw" = "$known" ]; then found=true; break; fi
    done
    if [ "$found" = false ]; then
      echo "error: unknown framework '$fw' (in compose: ${ALL_FRAMEWORKS[*]})" >&2
      echo "hint: add it under frameworks/ then run: bash bench/run.sh --write-compose" >&2
      exit 1
    fi
  done
else
  FRAMEWORKS=("${ALL_FRAMEWORKS[@]}")
fi

env_truthy() {
  case "${1:-}" in
    ""|0|false|no|NO|False) return 1 ;;
    *) return 0 ;;
  esac
}

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

images_ready() {
  for fw in "${FRAMEWORKS[@]}"; do
    image_exists "zig_web_bench-$fw" || return 1
  done
  image_exists "zig_web_bench-bencher"
}

echo "frameworks: ${FRAMEWORKS[*]}"
echo "compose:    $COMPOSE_PATH"
echo "output:     $RESULTS_DIR/results.zon"
echo ""

# ─── Build ───────────────────────────────────────────────────────────────────
if env_truthy "${BENCH_SKIP_BUILD:-}" && ! env_truthy "${BENCH_FORCE_BUILD:-}"; then
  echo "BENCH_SKIP_BUILD set — using existing images"
elif ! env_truthy "${BENCH_FORCE_BUILD:-}" && images_ready; then
  echo "images already present — skipping docker build (BENCH_FORCE_BUILD=1 to rebuild)"
else
  echo "Building containers..."
  "${COMPOSE[@]}" build bencher "${FRAMEWORKS[@]}"
fi

# Clear prior partials; keep results.zon until merge rewrites it.
find "$RESULTS_DIR" -maxdepth 1 -type f -name '.bench-*.zon' -delete 2>/dev/null || true

# Tear down leftovers from interrupted runs.
"${COMPOSE[@]}" down --remove-orphans -t 0 >/dev/null 2>&1 || true

# ─── Benchmark (one framework at a time) ─────────────────────────────────────
for fw in "${FRAMEWORKS[@]}"; do
  echo "── framework $fw ──"

  "${COMPOSE[@]}" up -d --wait --force-recreate "$fw"

  run_args=(
    run --rm --no-deps
    -e "BENCH_FRAMEWORKS=$fw"
  )
  if [ -n "${BENCH_PLATFORM:-}" ]; then
    run_args+=(-e "BENCH_PLATFORM=$BENCH_PLATFORM")
  fi
  if [ -n "${BENCH_SCENARIOS:-}" ]; then
    run_args+=(-e "BENCH_SCENARIOS=$BENCH_SCENARIOS")
  fi
  run_args+=(-v "$RESULTS_DIR:/out" bencher /out/results.zon)

  # OrbStack + zio/io_uring occasionally SIGBUS/SIGTRAP under load — retry.
  attempt=0
  while true; do
    if "${COMPOSE[@]}" "${run_args[@]}"; then
      break
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 3 ]; then
      echo "error: bencher failed for $fw after 3 attempts" >&2
      "${COMPOSE[@]}" stop -t 0 "$fw" >/dev/null 2>&1 || true
      exit 1
    fi
    echo "warn: bencher $fw failed; retry $attempt/3"
    "${COMPOSE[@]}" up -d --wait --force-recreate "$fw" || true
  done

  "${COMPOSE[@]}" stop -t 0 "$fw" >/dev/null 2>&1 || true
done

# ─── Merge partials → results.zon ────────────────────────────────────────────
echo "Merging results..."
"${COMPOSE[@]}" run --rm --no-deps \
  -v "$RESULTS_DIR:/out" \
  bencher --merge /out/results.zon

"${COMPOSE[@]}" down --remove-orphans -t 0 >/dev/null 2>&1 || true

echo "done → $RESULTS_DIR/results.zon"
