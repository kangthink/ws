#!/usr/bin/env bash
# ws - Workspace maintenance CLI
# Usage: ws <command> [options]
#   status                    Show workspace summary
#   clean [--months N] [--dry-run]  Clean stale project dependencies

set -euo pipefail

WORKSPACE="$HOME/workspace"
DEFAULT_MONTHS=6

# ── Colors ────────────────────────────────────────────────────────
info()  { printf "\033[1;34m[ws]\033[0m %s\n" "$1"; }
ok()    { printf "\033[1;32m[ws]\033[0m %s\n" "$1"; }
warn()  { printf "\033[1;33m[ws]\033[0m %s\n" "$1"; }
err()   { printf "\033[1;31m[ws]\033[0m %s\n" "$1" >&2; }
dim()   { printf "\033[0;90m%s\033[0m" "$1"; }
bold()  { printf "\033[1m%s\033[0m" "$1"; }

# ── Cleanup targets ──────────────────────────────────────────────
CLEAN_DIRS=(
  node_modules .venv venv __pycache__
  dist .next .turbo .nuxt
  coverage .pytest_cache .mypy_cache
)

# ── Helpers ───────────────────────────────────────────────────────
find_projects() {
  find "$WORKSPACE" -maxdepth 3 -mindepth 2 -type d \
    ! -path '*/.*' \
    ! -path '*/node_modules/*' \
    ! -path '*/__pycache__/*' \
    ! -path '*/.venv/*' \
    ! -path '*/venv/*' \
    ! -path '*/dist/*' \
    ! -path '*/coverage/*' \
    ! -path '*/out/*' \
    ! -path '*/.next/*' \
    ! -path '*/.turbo/*' \
    ! -path '*/.nuxt/*' \
    ! -path '*/.mypy_cache/*' \
    ! -path '*/.pytest_cache/*' \
    -print 2>/dev/null \
    | while read -r dir; do
        # Only include if it looks like a project root
        if [[ -d "$dir/.git" ]] || [[ -f "$dir/package.json" ]] || \
           [[ -f "$dir/pyproject.toml" ]] || [[ -f "$dir/Cargo.toml" ]] || \
           [[ -f "$dir/go.mod" ]] || [[ -f "$dir/Makefile" ]] || \
           [[ -f "$dir/requirements.txt" ]] || [[ -f "$dir/setup.py" ]]; then
          echo "$dir"
        fi
      done \
    | sort
}

last_activity_ts() {
  local dir="$1"
  if [[ -d "$dir/.git" ]]; then
    local ts
    ts=$(git -C "$dir" log -1 --format=%ct 2>/dev/null || echo "0")
    if [[ "$ts" != "0" ]] && [[ -n "$ts" ]]; then
      echo "$ts"
      return
    fi
  fi
  # Fallback: most recent file modification in top level
  local newest
  newest=$(find "$dir" -maxdepth 1 -type f -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1)
  echo "${newest:-0}"
}

last_activity_date() {
  local ts="$1"
  if [[ "$ts" -gt 0 ]]; then
    date -r "$ts" '+%Y-%m-%d'
  else
    echo "unknown"
  fi
}

relative_path() {
  echo "${1#"$WORKSPACE/"}"
}

human_size() {
  du -sh "$1" 2>/dev/null | cut -f1 | tr -d ' '
}

months_ago_ts() {
  local months="$1"
  local seconds=$((months * 30 * 24 * 3600))
  local now
  now=$(date +%s)
  echo $((now - seconds))
}

git_status_label() {
  local dir="$1"
  if [[ ! -d "$dir/.git" ]]; then
    echo "no-git"
    return
  fi
  local dirty=""
  if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
    dirty="dirty"
  fi
  # Check if behind remote (only if remote exists)
  local behind=""
  if git -C "$dir" rev-parse --abbrev-ref '@{upstream}' &>/dev/null; then
    git -C "$dir" fetch --quiet 2>/dev/null || true
    local behind_count
    behind_count=$(git -C "$dir" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo "0")
    if [[ "$behind_count" -gt 0 ]]; then
      behind="behind"
    fi
  fi
  if [[ -n "$dirty" ]] && [[ -n "$behind" ]]; then
    echo "dirty+behind"
  elif [[ -n "$dirty" ]]; then
    echo "dirty"
  elif [[ -n "$behind" ]]; then
    echo "behind"
  else
    echo "clean"
  fi
}

# ── Status Command ────────────────────────────────────────────────
cmd_status() {
  local detail=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detail|-d) detail=true ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
  done

  info "Scanning $WORKSPACE ..."
  echo ""

  local now
  now=$(date +%s)
  local threshold_active threshold_inactive
  threshold_active=$(months_ago_ts 1)
  threshold_inactive=$(months_ago_ts 6)

  local total=0 active=0 inactive=0 stale=0
  local clean=0 dirty=0 behind=0 nogit=0
  local total_dep_size=0
  local -a categories=()
  local -a project_lines=()

  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    total=$((total + 1))

    local rel
    rel=$(relative_path "$project")
    local cat
    cat=$(echo "$rel" | cut -d'/' -f1)

    # Track categories
    local found=false
    for c in "${categories[@]+"${categories[@]}"}"; do
      if [[ "$c" == "$cat" ]]; then found=true; break; fi
    done
    if [[ "$found" == "false" ]]; then
      categories+=("$cat")
    fi

    # Activity
    local ts
    ts=$(last_activity_ts "$project")
    local activity_label
    if [[ "$ts" -ge "$threshold_active" ]]; then
      active=$((active + 1))
      activity_label="active"
    elif [[ "$ts" -ge "$threshold_inactive" ]]; then
      inactive=$((inactive + 1))
      activity_label="inactive"
    else
      stale=$((stale + 1))
      activity_label="stale"
    fi

    # Git status (skip fetch for status overview - too slow)
    local git_label
    if [[ ! -d "$project/.git" ]]; then
      nogit=$((nogit + 1))
      git_label="no-git"
    elif [[ -n "$(git -C "$project" status --porcelain 2>/dev/null)" ]]; then
      dirty=$((dirty + 1))
      git_label="dirty"
    else
      clean=$((clean + 1))
      git_label="clean"
    fi

    if [[ "$detail" == "true" ]]; then
      local date_str
      date_str=$(last_activity_date "$ts")
      project_lines+=("${rel}|${activity_label}|${git_label}|${date_str}")
    fi
  done < <(find_projects)

  # Count dependency dirs and size
  local dep_count=0
  local dep_size_display=""
  local total_bytes=0
  for d in "${CLEAN_DIRS[@]}"; do
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      dep_count=$((dep_count + 1))
      local bytes
      bytes=$(du -sk "$match" 2>/dev/null | cut -f1 || echo "0")
      total_bytes=$((total_bytes + bytes))
    done < <(find "$WORKSPACE" -maxdepth 4 -type d -name "$d" 2>/dev/null)
  done
  if [[ "$total_bytes" -gt 0 ]]; then
    if [[ "$total_bytes" -ge 1048576 ]]; then
      dep_size_display="$(echo "scale=1; $total_bytes / 1048576" | bc)G"
    elif [[ "$total_bytes" -ge 1024 ]]; then
      dep_size_display="$(echo "scale=0; $total_bytes / 1024" | bc)M"
    else
      dep_size_display="${total_bytes}K"
    fi
  fi

  # ── Output ──
  printf "  \033[1m── Workspace Summary ──\033[0m\n\n"

  printf "  %-20s %s\n" "Projects:" "$total"
  printf "  %-20s " "Categories:"
  printf "%s" "${categories[*]}"
  echo ""
  echo ""

  printf "  \033[1m── Activity ──\033[0m\n"
  printf "  %-20s \033[1;32m%s\033[0m\n" "Active (<1 mo):" "$active"
  printf "  %-20s \033[1;33m%s\033[0m\n" "Inactive (1-6 mo):" "$inactive"
  printf "  %-20s \033[0;90m%s\033[0m\n" "Stale (>6 mo):" "$stale"
  echo ""

  printf "  \033[1m── Git Status ──\033[0m\n"
  printf "  %-20s %s\n" "Clean:" "$clean"
  printf "  %-20s \033[1;33m%s\033[0m\n" "Dirty:" "$dirty"
  printf "  %-20s %s\n" "No git:" "$nogit"
  echo ""

  printf "  \033[1m── Dependencies ──\033[0m\n"
  printf "  %-20s %s\n" "Dep directories:" "$dep_count"
  printf "  %-20s %s\n" "Total size:" "${dep_size_display:-0}"
  echo ""

  if [[ "$stale" -gt 0 ]]; then
    dim "  Tip: run 'ws clean --dry-run' to see reclaimable space"
    echo ""
  fi

  # ── Detail: per-project list ──
  if [[ "$detail" == "true" ]] && [[ ${#project_lines[@]} -gt 0 ]]; then
    printf "  \033[1m── Projects ──\033[0m\n\n"
    printf "  \033[0;90m%-35s %-10s %-8s %s\033[0m\n" "NAME" "ACTIVITY" "GIT" "LAST"
    for line in "${project_lines[@]}"; do
      IFS='|' read -r p_rel p_activity p_git p_date <<< "$line"
      local color
      case "$p_activity" in
        active)   color="\033[1;32m" ;;
        inactive) color="\033[1;33m" ;;
        stale)    color="\033[0;90m" ;;
      esac
      local git_color
      case "$p_git" in
        dirty)  git_color="\033[1;33m" ;;
        no-git) git_color="\033[0;90m" ;;
        *)      git_color="\033[0m" ;;
      esac
      printf "  %-35s ${color}%-10s\033[0m ${git_color}%-8s\033[0m %s\n" \
        "$p_rel" "$p_activity" "$p_git" "$p_date"
    done
    echo ""
  fi
}

# ── Clean Command ─────────────────────────────────────────────────
cmd_clean() {
  local months="$DEFAULT_MONTHS"
  local dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --months)
        shift
        months="${1:?'--months requires a number'}"
        ;;
      --dry-run)
        dry_run=true
        ;;
      *)
        err "Unknown option: $1"
        exit 1
        ;;
    esac
    shift
  done

  info "Scanning $WORKSPACE ..."

  local threshold
  threshold=$(months_ago_ts "$months")
  local now_date
  now_date=$(date +%s)

  # Collect stale projects with cleanable deps
  local -a targets=()       # "project_path|dep_dir|size_human|size_kb"
  local total_kb=0

  while IFS= read -r project; do
    [[ -z "$project" ]] && continue

    local ts
    ts=$(last_activity_ts "$project")

    # Skip if recently active
    [[ "$ts" -ge "$threshold" ]] && continue

    local date_str
    date_str=$(last_activity_date "$ts")
    local rel
    rel=$(relative_path "$project")

    # Check for cleanable directories
    for d in "${CLEAN_DIRS[@]}"; do
      local target="$project/$d"
      [[ ! -d "$target" ]] && continue

      # Skip build/ if it looks like an iOS project (contains .app, .xcarchive, etc)
      if [[ "$d" == "build" ]]; then
        if [[ -d "$project/$d/Build" ]] || \
           find "$project/$d" -maxdepth 1 -name "*.app" -o -name "*.xcarchive" 2>/dev/null | grep -q .; then
          continue
        fi
      fi

      local kb
      kb=$(du -sk "$target" 2>/dev/null | cut -f1 || echo "0")
      local human
      human=$(human_size "$target")
      targets+=("${rel}|${d}|${human}|${kb}|${date_str}|${target}")
      total_kb=$((total_kb + kb))
    done
  done < <(find_projects)

  if [[ ${#targets[@]} -eq 0 ]]; then
    ok "No stale dependencies found (threshold: ${months} months)"
    return
  fi

  # Calculate total human-readable
  local total_human
  if [[ "$total_kb" -ge 1048576 ]]; then
    total_human="$(echo "scale=1; $total_kb / 1048576" | bc)G"
  elif [[ "$total_kb" -ge 1024 ]]; then
    total_human="$(echo "scale=0; $total_kb / 1024" | bc)M"
  else
    total_human="${total_kb}K"
  fi

  echo ""
  printf "  \033[1m── Stale Projects (>%s months) with dependencies ──\033[0m\n\n" "$months"

  # Group by project for display
  local prev_project=""
  for entry in "${targets[@]}"; do
    IFS='|' read -r rel dep human kb date full_path <<< "$entry"
    if [[ "$rel" != "$prev_project" ]]; then
      if [[ -n "$prev_project" ]]; then
        echo ""
      fi
      printf "  \033[0;37m%-35s\033[0m \033[0;90mlast: %s\033[0m\n" "$rel" "$date"
      prev_project="$rel"
    fi
    printf "    %-20s \033[1;33m%5s\033[0m\n" "$dep/" "$human"
  done

  echo ""
  printf "  Total reclaimable: \033[1m~%s\033[0m\n" "$total_human"
  echo ""

  if [[ "$dry_run" == "true" ]]; then
    warn "Dry run — nothing deleted"
    return
  fi

  # Interactive confirmation
  printf "  Clean these? [y/N] "
  read -r confirm
  if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    info "Cancelled"
    return
  fi

  echo ""
  local cleaned=0
  local cleaned_kb=0
  for entry in "${targets[@]}"; do
    IFS='|' read -r rel dep human kb date full_path <<< "$entry"
    rm -rf "$full_path"
    cleaned=$((cleaned + 1))
    cleaned_kb=$((cleaned_kb + kb))
    ok "Removed $rel/$dep/ ($human)"
  done

  local cleaned_human
  if [[ "$cleaned_kb" -ge 1048576 ]]; then
    cleaned_human="$(echo "scale=1; $cleaned_kb / 1048576" | bc)G"
  elif [[ "$cleaned_kb" -ge 1024 ]]; then
    cleaned_human="$(echo "scale=0; $cleaned_kb / 1024" | bc)M"
  else
    cleaned_human="${cleaned_kb}K"
  fi

  echo ""
  ok "Cleaned $cleaned directories, freed ~$cleaned_human"
}

# ── Usage ─────────────────────────────────────────────────────────
usage() {
  echo "Usage: ws <command> [options]"
  echo ""
  echo "Commands:"
  echo "  status [--detail|-d]       Show workspace summary (--detail: list projects)"
  echo "  clean [--months N] [--dry-run]  Clean stale project dependencies"
  echo ""
  echo "Options:"
  echo "  --months N    Months of inactivity threshold (default: 6)"
  echo "  --dry-run     Show what would be cleaned without deleting"
  echo "  -h, --help    Show this help"
}

# ── Main ──────────────────────────────────────────────────────────
main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    status)  cmd_status "$@" ;;
    clean)   cmd_clean "$@" ;;
    -h|--help) usage ;;
    *)
      err "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
