#!/usr/bin/env bash
# ci-speed harness: per-variant setup, shared by every benchmark workflow.
# Usage: variant.sh <step>   (step: info | mtime | tools | record)
# Inputs (env): VARIANT, CACHE (none|rc|golden|sccache), LINKER (default|mold|wild),
#               WRAPPER (none|zthreads), BENCH_DIR (where records go).
set -euo pipefail
step=$1
BENCH_DIR=${BENCH_DIR:-$RUNNER_TEMP/bench}
mkdir -p "$BENCH_DIR"

case $step in
info)
  {
    echo "variant=$VARIANT cache=$CACHE linker=${LINKER:-default} wrapper=${WRAPPER:-none} preset=${PRESET:-} extra_env=${EXTRA_ENV:-}"
    env | grep -E '^CARGO_PROFILE|^RUSTFLAGS|^CARGO_INCREMENTAL' | sort
    echo "runner=$RUNNER_NAME os=$RUNNER_OS arch=$RUNNER_ARCH image=${ImageOS:-?}-${ImageVersion:-?}"
    echo "nproc=$(nproc)"
    grep -m1 'model name' /proc/cpuinfo || lscpu | grep -m1 -i 'model name' || true
    free -g | sed -n 2p
    df -h / /mnt 2>/dev/null | tail -n +2
  } | tee "$BENCH_DIR/info.txt"
  ;;

mtime)
  # Golden target: make Cargo's mtime freshness match content. Every tracked file gets one fixed
  # old mtime (older than any cached build output); files that differ from the golden's commit
  # get "now", so exactly those crates (and their dependents) rebuild. Without this, checkout's
  # fresh mtimes make every workspace crate stale even when the target is restored.
  # Directories too: `rerun-if-changed=<dir>` makes Cargo compare the directory's own mtime.
  git ls-files -z | xargs -0 touch -h -d @1500000000
  dirs_of() { awk -F/ '{p=""; for (i=1;i<NF;i++) {p = p (i>1?"/":"") $i; print p}} END {print "."}' | sort -u; }
  git ls-files -z | tr "\0" "\n" | dirs_of | tr '\n' '\0' | xargs -0 touch -h -d @1500000000
  base=$(cat target/.golden-sha 2>/dev/null || true)
  head=$(git rev-parse HEAD)
  echo "golden base=${base:-none} head=$head" | tee -a "$BENCH_DIR/info.txt"
  if [[ -n $base && $base != "$head" ]]; then
    git cat-file -e "$base^{commit}" 2>/dev/null || git fetch -q --depth=50 origin "$base"
    # Files changed since the golden get "now"; so do their directories (added/removed entries).
    git diff --name-only -z "$base" "$head" | xargs -0 -r touch -c
    git diff --name-only -z "$base" "$head" | tr "\0" "\n" | dirs_of | tr '\n' '\0' | xargs -0 -r touch -c
    git diff --name-only "$base" "$head" | wc -l | sed 's/^/changed files since golden: /' | tee -a "$BENCH_DIR/info.txt"
  fi
  ;;

tools)
  # PRESET deps3: dependencies optimised (opt-level 3), workspace crates as the profile says.
  if [[ ${PRESET:-} == *deps3* ]]; then
    mkdir -p .cargo
    printf '\n[profile.dev.package."*"]\nopt-level = 3\n' >> .cargo/config.toml
  fi
  # EXTRA_ENV: space-separated NAME=VALUE pairs for this variant (profile overrides etc.).
  for kv in ${EXTRA_ENV:-}; do echo "$kv" >> "$GITHUB_ENV"; done
  case ${LINKER:-default} in
  default) ;;
  mold)
    sudo apt-get install -y -qq mold >/dev/null
    echo "RUSTFLAGS=${RUSTFLAGS:-} -C link-arg=-fuse-ld=mold -C linker-features=-lld -C link-self-contained=-linker" >> "$GITHUB_ENV"
    ;;
  wild)
    v=0.11.0
    a=$(uname -m)
    curl -sSfL "https://github.com/davidlattimore/wild/releases/download/$v/wild-linker-$v-$a-unknown-linux-gnu.tar.gz" | tar xz -C "$RUNNER_TEMP"
    mkdir -p "$RUNNER_TEMP/wild-bin"
    ln -sf "$(find "$RUNNER_TEMP" -maxdepth 2 -name wild -type f | head -1)" "$RUNNER_TEMP/wild-bin/ld"
    echo "RUSTFLAGS=${RUSTFLAGS:-} -C link-arg=-B$RUNNER_TEMP/wild-bin -C linker-features=-lld -C link-self-contained=-linker" >> "$GITHUB_ENV"
    ;;
  esac
  case ${WRAPPER:-none} in
  none) ;;
  zthreads)
    # Nightly front-end threads on stable rustc, workspace crates only (as in the lab): a wrapper
    # sets RUSTC_BOOTSTRAP for workspace rustc invocations, so dependency build-script probes
    # (anyhow, etc.) never see nightly features.
    cat > "$RUNNER_TEMP/zthreads.sh" <<EOF
#!/usr/bin/env bash
rustc=\$1; shift
RUSTC_BOOTSTRAP=1 exec "\$rustc" "\$@" -Zthreads=$(nproc) -Zshare-generics=y
EOF
    chmod +x "$RUNNER_TEMP/zthreads.sh"
    echo "RUSTC_WORKSPACE_WRAPPER=$RUNNER_TEMP/zthreads.sh" >> "$GITHUB_ENV"
    ;;
  esac
  if [[ $CACHE == sccache ]]; then
    echo "SCCACHE_GHA_ENABLED=true" >> "$GITHUB_ENV"
    echo "RUSTC_WRAPPER=sccache" >> "$GITHUB_ENV"
  fi
  ;;

record)
  {
    echo "--- after"
    df -h / | tail -1
    du -sh target 2>/dev/null || true
    du -sh ~/.cargo/registry 2>/dev/null || true
    if [[ $CACHE == sccache ]]; then sccache --show-stats || true; fi
    # Which linker produced the binaries (Wild/mold/LLD all leave a .comment entry).
    bin=$(find target/*/deps -maxdepth 1 -type f -executable -size +1M 2>/dev/null | head -1)
    [[ -n $bin ]] && { echo "linker check: $bin"; readelf -p .comment "$bin" 2>/dev/null | grep -i -E 'wild|mold|lld|gnu ld|GCC' | head -4; }
  } | tee -a "$BENCH_DIR/info.txt"
  mkdir -p "$BENCH_DIR/timings"
  cp target/cargo-timings/cargo-timing-*.html "$BENCH_DIR/timings/" 2>/dev/null || true
  ;;
esac
