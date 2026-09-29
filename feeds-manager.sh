#!/usr/bin/env bash
# Manage extra OpenWrt/ImmortalWrt package feeds without editing build.yml.
# Configuration format: enabled|name|git-url|branch
# Use "-" as the branch to use the repository's default branch.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config_file="${CUSTOM_FEEDS_FILE:-${script_dir}/custom-feeds.conf}"
block_start="# BEGIN custom feeds (managed by feeds-manager.sh)"
block_end="# END custom feeds (managed by feeds-manager.sh)"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./feeds-manager.sh list
  ./feeds-manager.sh add <name> <git-url> [branch]
  ./feeds-manager.sh remove <name>
  ./feeds-manager.sh enable <name>
  ./feeds-manager.sh disable <name>
  ./feeds-manager.sh apply [immortalwrt-source-directory]

Examples:
  ./feeds-manager.sh add myfeed https://github.com/example/openwrt-feed main
  ./feeds-manager.sh disable myfeed
  ./feeds-manager.sh apply immortalwrt
EOF
}

require_config() {
  [ -f "$config_file" ] || die "Configuration file not found: $config_file"
}

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid feed name: $1"
}

validate_url() {
  case "$1" in
    https://*|http://*|ssh://*|git@*) ;;
    *) die "Git URL must start with https://, http://, ssh://, or git@" ;;
  esac
  [[ "$1" != *'|'* && "$1" != *[[:space:]]* ]] || die "Git URL cannot contain spaces or |"
}

validate_branch() {
  [ "$1" = "-" ] && return
  [[ "$1" != *'|'* && "$1" != *[[:space:]]* && -n "$1" ]] || die "Invalid branch: $1"
}

rewrite_config() {
  local tmp_file
  tmp_file="$(mktemp "${config_file}.tmp.XXXXXX")"
  "$@" > "$tmp_file"
  mv "$tmp_file" "$config_file"
}

add_feed() {
  local name="$1" url="$2" branch="${3:--}"
  local record
  require_config
  validate_name "$name"
  validate_url "$url"
  validate_branch "$branch"
  record="1|${name}|${url}|${branch}"

  rewrite_config awk -F'|' -v name="$name" -v record="$record" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    $2 == name { if (!replaced) print record; replaced = 1; next }
    { print }
    END { if (!replaced) print record }
  ' "$config_file"

  echo "Saved and enabled feed: $name"
}

remove_feed() {
  local name="$1"
  require_config
  validate_name "$name"

  if ! awk -F'|' -v name="$name" '$2 == name { found = 1 } END { exit !found }' "$config_file"; then
    die "Feed not found: $name"
  fi

  rewrite_config awk -F'|' -v name="$name" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    $2 != name { print }
  ' "$config_file"
  echo "Removed feed: $name"
}

set_enabled() {
  local name="$1" enabled="$2"
  require_config
  validate_name "$name"

  if ! awk -F'|' -v name="$name" '$2 == name { found = 1 } END { exit !found }' "$config_file"; then
    die "Feed not found: $name"
  fi

  rewrite_config awk -F'|' -v name="$name" -v enabled="$enabled" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    $2 == name { $1 = enabled }
    { print }
  ' OFS='|' "$config_file"
  echo "$( [ "$enabled" = 1 ] && echo Enabled || echo Disabled ) feed: $name"
}

list_feeds() {
  require_config
  printf '%-10s %-22s %-55s %s\n' "STATUS" "NAME" "URL" "BRANCH"
  printf '%-10s %-22s %-55s %s\n' "------" "----" "---" "------"
  awk -F'|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1 == "1" { status = "enabled" }
    $1 == "0" { status = "disabled" }
    $1 == "1" || $1 == "0" { printf "%-10s %-22s %-55s %s\n", status, $2, $3, $4; next }
    { printf "INVALID    %s\n", $0 > "/dev/stderr"; invalid = 1 }
    END { exit invalid }
  ' "$config_file"
}

apply_feeds() {
  local source_dir="${1:-immortalwrt}"
  local feeds_file="${source_dir}/feeds.conf.default"
  local clean_file additions_file line enabled name url branch extra active_count=0

  require_config
  [ -f "$feeds_file" ] || die "ImmortalWrt feeds file not found: $feeds_file"

  clean_file="$(mktemp "${feeds_file}.custom.XXXXXX")"
  additions_file="$(mktemp "${feeds_file}.additions.XXXXXX")"
  trap 'rm -f "$clean_file" "$additions_file"' EXIT

  # Remove a block left by a previous run, so applying is idempotent.
  awk -v start="$block_start" -v end="$block_end" '
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$feeds_file" > "$clean_file"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    IFS='|' read -r enabled name url branch extra <<< "$line"
    [ -z "${extra:-}" ] || die "Invalid custom feed entry: $line"
    [ "$enabled" = "0" ] || [ "$enabled" = "1" ] || die "Enabled flag must be 0 or 1: $line"
    validate_name "$name"
    validate_url "$url"
    validate_branch "$branch"

    [ "$enabled" = "1" ] || continue

    if grep -Eq "^src-git(-full)?[[:space:]]+${name}([[:space:]]|$)" "$clean_file"; then
      die "Feed name '$name' already exists in ImmortalWrt's feeds.conf.default"
    fi

    if [ "$branch" = "-" ]; then
      printf 'src-git %s %s\n' "$name" "$url" >> "$additions_file"
    else
      printf 'src-git %s %s;%s\n' "$name" "$url" "$branch" >> "$additions_file"
    fi
    active_count=$((active_count + 1))
  done < "$config_file"

  # Append a newly generated block, after old managed entries were removed above.
  printf '\n%s\n' "$block_start" >> "$clean_file"
  cat "$additions_file" >> "$clean_file"
  printf '%s\n' "$block_end" >> "$clean_file"

  mv "$clean_file" "$feeds_file"
  trap - EXIT

  echo "Applied ${active_count} custom feed(s) to ${feeds_file}"
}

command="${1:-}"
case "$command" in
  list)
    [ "$#" -eq 1 ] || { usage; exit 1; }
    list_feeds
    ;;
  add)
    [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || { usage; exit 1; }
    add_feed "$2" "$3" "${4:--}"
    ;;
  remove)
    [ "$#" -eq 2 ] || { usage; exit 1; }
    remove_feed "$2"
    ;;
  enable)
    [ "$#" -eq 2 ] || { usage; exit 1; }
    set_enabled "$2" 1
    ;;
  disable)
    [ "$#" -eq 2 ] || { usage; exit 1; }
    set_enabled "$2" 0
    ;;
  apply)
    [ "$#" -eq 1 ] || [ "$#" -eq 2 ] || { usage; exit 1; }
    apply_feeds "${2:-immortalwrt}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
