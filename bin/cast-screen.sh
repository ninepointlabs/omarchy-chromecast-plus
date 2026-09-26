#!/usr/bin/env bash
# cast-screen.sh: create/remove a virtual (headless) Hyprland output sized for a
# TV so desktop casting captures a native 16:9 surface instead of a downscaled
# laptop panel. Usable standalone (keybinds) and from the Chromecast widget.
#
#   cast-screen.sh on | off | toggle | status [--json]
#
# Only outputs named CAST or HEADLESS-<n> are ever created, moved from, or
# removed; physical outputs (eDP-*, HDMI-*, DP-*, ...) are never touched.
set -euo pipefail

prog="cast-screen.sh"
managed_re='^(CAST|HEADLESS-[0-9]+)$'

usage() {
  cat <<EOF
Usage: $prog <command>

Commands:
  on              Create the virtual TV output (no-op if one already exists)
  off             Remove the virtual TV output; its workspaces move to a real monitor
  toggle          Run 'off' if the output exists, otherwise 'on'
  status [--json] Report whether the virtual TV output exists
                  (plain: exit 0 active, 3 inactive; --json: exit 0 either way)

Settings (environment overrides the config file):
  CAST_SCREEN_RESOLUTION  default 1920x1080
  CAST_SCREEN_REFRESH     default 60
  CAST_SCREEN_SCALE       default 1.5 (larger text survives cast compression)
  CAST_SCREEN_WORKSPACE   workspace id to move onto the output (default: none)
  CAST_SCREEN_NOTIFY      set to 0 to disable desktop notifications
  CAST_SCREEN_CONFIG      config file (default: \${XDG_CONFIG_HOME:-~/.config}/cast-screen.conf)

Config file lines look like RESOLUTION=2560x1440 (the CAST_SCREEN_ prefix is optional).
EOF
}

notify() {
  local urgency="$1" title="$2" body="$3"
  [[ "${CAST_SCREEN_NOTIFY:-1}" != "0" ]] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send --app-name="Cast screen" --urgency="$urgency" "$title" "$body" >/dev/null 2>&1 || true
}

# Print an error, notify (for user-facing actions), and exit 1.
fail() {
  local action="$1" message="$2"
  echo "$prog: $message" >&2
  if [[ -n "$action" ]]; then
    notify critical "TV screen: $action failed" "$message"
  fi
  exit 1
}

warn() {
  echo "$prog: warning: $*" >&2
}

require_tools() {
  local action="$1"
  command -v jq >/dev/null 2>&1 \
    || fail "$action" "jq is required but not installed (install it with: sudo pacman -S jq)"
  command -v hyprctl >/dev/null 2>&1 \
    || fail "$action" "hyprctl not found; is this a Hyprland session?"
}

# ---------------------------------------------------------------------------
# Configuration

load_config() {
  local action="$1"
  local file="${CAST_SCREEN_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/cast-screen.conf}"
  local file_resolution="" file_refresh="" file_scale="" file_workspace=""

  if [[ -f "$file" ]]; then
    # Parsed as KEY=value data, never sourced, so the file cannot run code.
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -n "$line" ]] || continue
      if [[ "$line" =~ ^(CAST_SCREEN_)?([A-Z]+)[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?$ ]]; then
        key="${BASH_REMATCH[2]}"
        value="${BASH_REMATCH[3]}"
        case "$key" in
          RESOLUTION) file_resolution="$value" ;;
          REFRESH) file_refresh="$value" ;;
          SCALE) file_scale="$value" ;;
          WORKSPACE) file_workspace="$value" ;;
          *) warn "ignoring unknown key '$key' in $file" ;;
        esac
      else
        warn "ignoring malformed line in $file: $line"
      fi
    done <"$file"
  fi

  resolution="${CAST_SCREEN_RESOLUTION:-${file_resolution:-1920x1080}}"
  refresh="${CAST_SCREEN_REFRESH:-${file_refresh:-60}}"
  scale="${CAST_SCREEN_SCALE:-${file_scale:-1.5}}"
  workspace="${CAST_SCREEN_WORKSPACE:-$file_workspace}"

  # Values are interpolated into Hyprland monitor rules, so accept only plain numbers.
  [[ "$resolution" =~ ^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$ ]] \
    || fail "$action" "invalid resolution '$resolution' (expected e.g. 1920x1080)"
  [[ "$refresh" =~ ^[1-9][0-9]{0,2}(\.[0-9]{1,3})?$ ]] \
    || fail "$action" "invalid refresh rate '$refresh' (expected e.g. 60)"
  [[ "$scale" =~ ^[0-9](\.[0-9]{1,4})?$ && ! "$scale" =~ ^0(\.0*)?$ ]] \
    || fail "$action" "invalid scale '$scale' (expected e.g. 1 or 1.5)"
  [[ -z "$workspace" || "$workspace" =~ ^[1-9][0-9]{0,2}$ ]] \
    || fail "$action" "invalid workspace '$workspace' (expected a workspace number)"
}

# ---------------------------------------------------------------------------
# State and locking

init_state() {
  local action="$1"
  local runtime="${XDG_RUNTIME_DIR:-}"
  [[ "$runtime" == /* && -d "$runtime" ]] \
    || fail "$action" "XDG_RUNTIME_DIR is not set to an existing absolute directory"
  state_dir="$runtime/cast-screen"
  state_file="$state_dir/output"
  [[ ! -L "$state_dir" ]] || fail "$action" "refusing symlinked state directory: $state_dir"
  mkdir -p -m 700 "$state_dir"
}

lock_state() {
  local action="$1"
  exec 9>"$state_dir/lock"
  flock -w 10 9 || fail "$action" "another cast-screen.sh command is still running"
}

read_state() {
  local name=""
  if [[ -f "$state_file" && ! -L "$state_file" ]]; then
    IFS= read -r name <"$state_file" || true
  fi
  [[ "$name" =~ $managed_re ]] && printf '%s\n' "$name" || true
}

write_state() {
  local tmp="$state_file.$$.tmp"
  printf '%s\n' "$1" >"$tmp"
  mv -f "$tmp" "$state_file"
}

clear_state() {
  rm -f "$state_file"
}

# ---------------------------------------------------------------------------
# Hyprland queries and commands

monitors_json() {
  local action="$1" json
  json=$(hyprctl -j monitors all 2>/dev/null) || fail "$action" "could not query Hyprland monitors (hyprctl -j monitors all)"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json" \
    || fail "$action" "unexpected output from hyprctl -j monitors all"
  printf '%s\n' "$json"
}

managed_names() {
  jq -r --arg re "$managed_re" '.[] | select(.name | test($re)) | .name' <<<"$1"
}

# The output this script considers "the" TV screen: the recorded one if it
# still exists, otherwise any CAST/HEADLESS-* output.
current_name() {
  local mons="$1" recorded names
  recorded=$(read_state)
  names=$(managed_names "$mons")
  if [[ -n "$recorded" ]] && grep -qxF -- "$recorded" <<<"$names"; then
    printf '%s\n' "$recorded"
  else
    head -n 1 <<<"$names"
  fi
}

# Hyprland 0.55+ with a Lua config rejects `keyword` (while still exiting 0)
# and takes Lua via eval/dispatch; older hyprlang configs are the reverse.
lua_mode() {
  if [[ -z "${lua_mode_cached:-}" ]]; then
    if [[ "$(hyprctl eval 'return 1' 2>/dev/null)" == "ok" ]]; then lua_mode_cached=yes; else lua_mode_cached=no; fi
  fi
  [[ "$lua_mode_cached" == "yes" ]]
}

# hyprctl exits 0 for warnings and some refusals, so require an "ok" reply.
hypr_ok() {
  local out
  out=$(hyprctl "$@" 2>&1) || { printf '%s\n' "$out" >&2; return 1; }
  [[ "$out" == ok* ]] || { printf '%s\n' "$out" >&2; return 1; }
}

apply_monitor_rule() {
  local name="$1" mode="$resolution@$refresh"
  if lua_mode; then
    hypr_ok eval "hl.monitor({ output = \"$name\", mode = \"$mode\", position = \"auto\", scale = $scale })"
  else
    hypr_ok keyword monitor "$name,$mode,auto,$scale"
  fi
}

move_workspace() {
  local ws="$1" monitor="$2"
  if lua_mode; then
    hypr_ok dispatch "hl.dsp.workspace.move({ workspace = $ws, monitor = \"$monitor\" })"
  else
    hypr_ok dispatch moveworkspacetomonitor "$ws" "$monitor"
  fi
}

# First enabled physical output, preferring the laptop panel.
fallback_monitor() {
  jq -r --arg re "$managed_re" '
    [.[] | select((.name | test($re) | not) and (.disabled != true)) | .name]
    | (map(select(startswith("eDP-"))) + .) | first // empty
  ' <<<"$1"
}

describe() {
  jq -r --arg n "$2" '.[] | select(.name == $n)
    | "\(.name) \(.width)x\(.height)@\(.refreshRate + 0.5 | floor) scale \(.scale)"' <<<"$1"
}

# ---------------------------------------------------------------------------
# Commands

cmd_on() {
  require_tools start
  load_config start
  init_state start
  lock_state start

  local mons existing
  mons=$(monitors_json start)
  existing=$(current_name "$mons")
  if [[ -n "$existing" ]]; then
    write_state "$existing"
    echo "TV screen already active: $(describe "$mons" "$existing")"
    notify normal "TV screen already on" "$existing is already active."
    return 0
  fi

  local before after name="" i
  before=$(jq -r '.[].name' <<<"$mons")
  hyprctl output create headless CAST >/dev/null 2>&1 || true

  # Some Hyprland versions ignore the requested name, so detect the new output
  # by diffing monitor names before and after creation.
  for ((i = 0; i < 25; i++)); do
    after=$(monitors_json start)
    if jq -e '.[] | select(.name == "CAST")' >/dev/null <<<"$after"; then
      name="CAST"
    else
      name=$(managed_names "$after" | grep -vxF -f <(printf '%s\n' "$before") | head -n 1 || true)
    fi
    [[ -z "$name" ]] || break
    sleep 0.2
  done
  [[ -n "$name" ]] || fail start "Hyprland did not create a headless output (hyprctl output create headless CAST)"
  write_state "$name"

  if ! apply_monitor_rule "$name"; then
    hyprctl output remove "$name" >/dev/null 2>&1 || true
    clear_state
    fail start "could not apply monitor rule $resolution@$refresh scale $scale to $name; removed it again"
  fi

  local moved=""
  if [[ -n "$workspace" ]]; then
    if move_workspace "$workspace" "$name"; then
      moved=" Workspace $workspace moved to it."
    else
      warn "could not move workspace $workspace to $name"
      moved=" Could not move workspace $workspace to it."
    fi
  fi

  mons=$(monitors_json start)
  echo "TV screen active: $(describe "$mons" "$name")"
  notify normal "TV screen on" "$name ($resolution@$refresh). Pick it in the screen-share prompt.$moved"
}

cmd_off() {
  require_tools stop
  init_state stop
  lock_state stop

  local mons recorded names targets
  mons=$(monitors_json stop)
  recorded=$(read_state)
  names=$(managed_names "$mons")
  if [[ -n "$recorded" ]] && grep -qxF -- "$recorded" <<<"$names"; then
    targets="$recorded"
  else
    # Missing or stale state: remove every CAST/HEADLESS-* output so the kill
    # button always leaves no virtual output behind.
    targets="$names"
  fi

  if [[ -z "$targets" ]]; then
    clear_state
    echo "TV screen already off"
    notify low "TV screen already off" "No virtual TV output was found."
    return 0
  fi

  local fallback
  fallback=$(fallback_monitor "$mons")
  [[ -n "$fallback" ]] \
    || fail stop "no physical monitor is available to receive windows; not removing $(tr '\n' ' ' <<<"$targets")"

  local name ws workspaces removed=() problems=()
  while IFS= read -r name; do
    [[ "$name" =~ $managed_re ]] || continue
    workspaces=$(hyprctl -j workspaces 2>/dev/null \
      | jq -r --arg n "$name" '.[] | select(.monitor == $n and .id > 0) | .id' 2>/dev/null || true)
    while IFS= read -r ws; do
      [[ -n "$ws" ]] || continue
      move_workspace "$ws" "$fallback" || problems+=("could not move workspace $ws from $name")
    done <<<"$workspaces"

    hyprctl output remove "$name" >/dev/null 2>&1 || true
    if managed_names "$(monitors_json stop)" | grep -qxF -- "$name"; then
      problems+=("Hyprland did not remove $name")
    else
      removed+=("$name")
    fi
  done <<<"$targets"

  if ((${#problems[@]} > 0)); then
    fail stop "$(IFS='; '; echo "${problems[*]}")"
  fi
  clear_state
  echo "TV screen removed: ${removed[*]} (windows moved to $fallback)"
  notify normal "TV screen off" "Removed ${removed[*]}. Windows moved to $fallback."
}

cmd_status() {
  local json=0
  case "${1:-}" in
    "") ;;
    --json) json=1 ;;
    *) echo "$prog: unknown status option: $1" >&2; exit 2 ;;
  esac
  require_tools ""
  init_state ""

  local mons name count
  mons=$(monitors_json "")
  name=$(current_name "$mons")
  count=$(managed_names "$mons" | grep -c . || true)

  if ((json)); then
    jq -c --arg n "$name" --argjson count "$count" '
      (map(select(.name == $n)) | first) as $m
      | if $m == null then {active: false, count: 0}
        else {active: true, name: $m.name, width: $m.width, height: $m.height,
              refreshRate: ($m.refreshRate + 0.5 | floor), scale: $m.scale, count: $count}
        end
    ' <<<"$mons"
    return 0
  fi

  if [[ -n "$name" ]]; then
    echo "active $(describe "$mons" "$name")"
    ((count <= 1)) || echo "note: $count virtual outputs exist; 'off' after a stale state removes all of them"
    return 0
  fi
  echo "inactive"
  return 3
}

cmd_toggle() {
  require_tools start
  init_state start
  local mons
  mons=$(monitors_json start)
  if [[ -n "$(current_name "$mons")" ]]; then cmd_off; else cmd_on; fi
}

case "${1:-}" in
  on) cmd_on ;;
  off) cmd_off ;;
  toggle) cmd_toggle ;;
  status) cmd_status "${2:-}" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
