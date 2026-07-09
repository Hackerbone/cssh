#!/usr/bin/env bash
#
# cssh — one-shot installer.
#
# Paste your local clipboard images straight into Claude Code (or any terminal
# app that reads xclip) running over SSH on a headless box.
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/cssh/main/install.sh | bash
#
# Runs on your laptop. Reads ~/.ssh/config, lets you pick which host(s) to
# enable, sets up SSH connection multiplexing, installs the local push/daemon,
# and installs the remote xclip shim over SSH. Uses `gum` for the menus if it is
# available, otherwise a plain built-in menu.
#
# Self-contained: every component is embedded below. No secondary downloads.

# This script uses bash features. If started under another shell, re-exec bash.
if [ -z "${BASH_VERSION:-}" ]; then
    if [ -r "${0:-}" ] && [ "${0:-}" != "-" ] && [ "${0:-}" != "bash" ]; then
        exec bash "$0" "$@"
    fi
    echo "cssh: please run with bash, e.g.  curl -fsSL <url> | bash" >&2
    exit 1
fi

set -euo pipefail

# All interactive input comes from the terminal, so `curl | bash` still works.
tty_in="/dev/tty"

# ----------------------------------------------------------------------------
# styling
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
    pink=$'\033[38;5;212m'; mauve=$'\033[38;5;183m'; green=$'\033[38;5;114m'
    red=$'\033[38;5;203m'; blue=$'\033[38;5;111m'
else
    bold=""; dim=""; reset=""; pink=""; mauve=""; green=""; red=""; blue=""
fi

banner() {
    printf '\n%s%s cssh %s%s clipboard images into Claude Code over SSH%s\n\n' \
        "$pink" "$bold" "$reset" "$dim" "$reset"
}
step()  { printf '%s%s›%s %s\n' "$mauve" "$bold" "$reset" "$1"; }
ok()    { printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }
info()  { printf '  %s•%s %s\n' "$blue" "$reset" "$1"; }
warn()  { printf '  %s!%s %s\n' "$red" "$reset" "$1"; }
die()   { printf '\n%s✗ %s%s\n' "$red" "$1" "$reset" >&2; exit 1; }

# ----------------------------------------------------------------------------
# gum-or-fallback UI helpers
# ----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

maybe_install_gum() {
    have gum && { HAS_GUM=1; return; }
    HAS_GUM=0
    printf '  %sgum%s makes the menus nicer (optional). Install it now? [y/N] ' "$mauve" "$reset"
    local answer; read -r answer < "$tty_in" || answer=""
    case "$answer" in
        y|Y)
            if have brew; then brew install gum && HAS_GUM=1
            elif have go; then go install github.com/charmbracelet/gum@latest && HAS_GUM=1
            else warn "no brew or go found; using the plain menu"; fi
            ;;
        *) : ;;
    esac
    have gum && HAS_GUM=1
}

# ui_confirm "question"  -> returns 0 for yes, 1 for no
ui_confirm() {
    local q="$1"
    if [ "${HAS_GUM:-0}" = "1" ]; then
        gum confirm "$q"
        return $?
    fi
    printf '  %s [y/N] ' "$q"
    local a; read -r a < "$tty_in" || a=""
    case "$a" in y|Y) return 0 ;; *) return 1 ;; esac
}

# ui_input "prompt" "placeholder" -> echoes the entered value
ui_input() {
    local prompt="$1" placeholder="${2:-}"
    if [ "${HAS_GUM:-0}" = "1" ]; then
        gum input --prompt "$prompt " --placeholder "$placeholder"
        return
    fi
    printf '  %s ' "$prompt" >&2
    local v; read -r v < "$tty_in" || v=""
    printf '%s' "$v"
}

# ui_choose_one "header" opt...  -> echoes the chosen option
ui_choose_one() {
    local header="$1"; shift
    if [ "${HAS_GUM:-0}" = "1" ]; then
        printf '%s\n' "$@" | gum choose --header "$header"
        return
    fi
    printf '  %s%s%s\n' "$bold" "$header" "$reset" >&2
    local i=1
    for opt in "$@"; do printf '   %s%2d%s) %s\n' "$mauve" "$i" "$reset" "$opt" >&2; i=$((i+1)); done
    printf '  choose a number: ' >&2
    local n; read -r n < "$tty_in" || n=""
    [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "$#" ] || die "invalid choice"
    eval "printf '%s' \"\${$n}\""
}

# ui_choose_multi "header" opt...  -> echoes chosen options, one per line
ui_choose_multi() {
    local header="$1"; shift
    if [ "${HAS_GUM:-0}" = "1" ]; then
        printf '%s\n' "$@" | gum choose --no-limit --header "$header"
        return
    fi
    printf '  %s%s%s %s(space/comma separated numbers)%s\n' "$bold" "$header" "$reset" "$dim" "$reset" >&2
    local i=1
    for opt in "$@"; do printf '   %s%2d%s) %s\n' "$mauve" "$i" "$reset" "$opt" >&2; i=$((i+1)); done
    printf '  pick: ' >&2
    local line; read -r line < "$tty_in" || line=""
    line="${line//,/ }"
    # Split explicitly so this behaves the same under bash and zsh.
    local picks pick
    read -ra picks <<< "$line"
    [ "${#picks[@]}" -gt 0 ] || return 0
    for pick in "${picks[@]}"; do
        [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "$#" ] && eval "printf '%s\n' \"\${$pick}\""
    done
}

# ----------------------------------------------------------------------------
# embedded components (verified). Quoted heredocs keep bodies verbatim.
# ----------------------------------------------------------------------------
emit_shim() {
cat <<'CSSH_SHIM_EOF'
#!/usr/bin/env bash
#
# cssh xclip shim. Claude Code reads pasted images on Linux by shelling out
# to `xclip`. On a headless SSH box the real xclip fails. This shim serves the
# image synced from your laptop to ~/.cssh/latest.png, and otherwise stays
# out of the way. One-shot (served once, then deleted) with a TTL guard.
#
# Claude Code's two calls we serve:
#   xclip -selection clipboard -t TARGETS   -o
#   xclip -selection clipboard -t image/png -o

set -u

home_dir="${HOME:-/home/$(id -un)}"
image_file="$home_dir/.cssh/latest.png"
ttl_file="$home_dir/.cssh/ttl"
ttl_seconds=300
if [ -f "$ttl_file" ]; then
    ttl_seconds="$(cat "$ttl_file")"
fi

args="$*"

image_is_fresh() {
    if [ ! -s "$image_file" ]; then
        return 1
    fi
    local now mtime age
    now="$(date +%s)"
    mtime="$(stat -c %Y "$image_file" 2>/dev/null || echo 0)"
    age=$((now - mtime))
    [ "$age" -le "$ttl_seconds" ]
}

find_real_xclip() {
    local self_dir this
    self_dir="$(cd "$(dirname "$0")" && pwd)"
    local IFS=:
    for dir in $PATH; do
        this="$dir/xclip"
        if [ "$dir" != "$self_dir" ] && [ -x "$this" ]; then
            echo "$this"
            return 0
        fi
    done
    return 1
}

delegate_or_exit() {
    local fallback_code="$1"
    shift
    local real
    if real="$(find_real_xclip)"; then
        exec "$real" "$@"
    fi
    # No real xclip. Exit quietly. We deliberately do NOT read stdin: Claude's
    # read/probe calls inherit an open pipe with no EOF, so draining it would
    # block forever and hang the paste.
    exit "$fallback_code"
}

case "$args" in
    *TARGETS*-o*|*-o*TARGETS*)
        if image_is_fresh; then
            echo "image/png"
            exit 0
        fi
        delegate_or_exit 1 "$@"
        ;;
    *image/png*-o*|*-o*image/png*)
        if image_is_fresh; then
            cat "$image_file"
            rm -f "$image_file"
            exit 0
        fi
        delegate_or_exit 1 "$@"
        ;;
    *)
        delegate_or_exit 0 "$@"
        ;;
esac
CSSH_SHIM_EOF
}

emit_lib() {
cat <<'CSSH_LIB_EOF'
#!/usr/bin/env bash
# Shared helpers for the cssh local side: read an image out of the OS
# clipboard (platform agnostic) and push it to the remote over a warm,
# multiplexed SSH connection. Config: ~/.cssh/config (REMOTE, REMOTE_IMAGE).

config_file="$HOME/.cssh/config"
if [ -f "$config_file" ]; then
    # shellcheck disable=SC1090
    . "$config_file"
fi
# Optional host override: `cssh-push somehost`
if [ -n "${1:-}" ]; then REMOTE="$1"; fi
: "${REMOTE:?Set REMOTE in ~/.cssh/config or pass a host argument}"
: "${REMOTE_IMAGE:=.cssh/latest.png}"

os_name="$(uname -s)"

extract_clipboard_png() {
    local out="$1"
    case "$os_name" in
        Darwin)
            local result
            result="$(osascript 2>/dev/null <<OSA
set outFile to POSIX file "$out"
try
    set pngData to (the clipboard as «class PNGf»)
on error
    return "NOIMAGE"
end try
set fp to open for access outFile with write permission
set eof fp to 0
write pngData to fp
close access fp
return "OK"
OSA
)"
            [ "$result" = "OK" ] && [ -s "$out" ]
            ;;
        Linux)
            if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then
                wl-paste --type image/png > "$out" 2>/dev/null
            else
                xclip -selection clipboard -t image/png -o > "$out" 2>/dev/null
            fi
            [ -s "$out" ]
            ;;
        MINGW*|MSYS*|CYGWIN*)
            powershell.exe -NoProfile -NonInteractive -Sta -Command \
'Add-Type -AssemblyName System.Windows.Forms; $i=[System.Windows.Forms.Clipboard]::GetImage(); if($null -eq $i){exit 1}; $ms=New-Object System.IO.MemoryStream; $i.Save($ms,[System.Drawing.Imaging.ImageFormat]::Png); [Convert]::ToBase64String($ms.ToArray())' \
2>/dev/null | tr -d '\r' | base64 -d > "$out"
            [ -s "$out" ]
            ;;
        *)
            echo "cssh: unsupported OS: $os_name" >&2
            return 1
            ;;
    esac
}

push_png_to_remote() {
    local pngfile="$1"
    ssh "$REMOTE" "mkdir -p ~/.cssh && cat > ~/.cssh/latest.png.tmp && mv -f ~/.cssh/latest.png.tmp ~/$REMOTE_IMAGE" < "$pngfile"
}

notify() {
    local msg="$1"
    if [ "$os_name" = "Darwin" ]; then
        osascript -e "display notification \"$msg\" with title \"cssh\"" >/dev/null 2>&1 || true
    fi
    echo "cssh: $msg"
}
CSSH_LIB_EOF
}

emit_push() {
cat <<'CSSH_PUSH_EOF'
#!/usr/bin/env bash
# One-shot: sync the current clipboard image to the remote. Bind to a hotkey.
# Optional: `cssh-push <host>` to target a specific host.
set -euo pipefail
lib_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$lib_dir/cssh-lib.sh" "${1:-}"
tmp_png="$(mktemp -t cssh.XXXXXX).png"
trap 'rm -f "$tmp_png"' EXIT
if ! extract_clipboard_png "$tmp_png"; then
    notify "no image in clipboard"; exit 1
fi
push_png_to_remote "$tmp_png"
notify "image synced — Ctrl+V in Claude Code"
CSSH_PUSH_EOF
}

emit_daemon() {
cat <<'CSSH_DAEMON_EOF'
#!/usr/bin/env bash
# Background watcher: auto-sync every new clipboard image to the remote.
set -euo pipefail
lib_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$lib_dir/cssh-lib.sh" "${1:-}"
poll_seconds="${CSSH_POLL_SECONDS:-1}"
hash_file() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else sha256sum "$1" | cut -d' ' -f1; fi
}
tmp_png="$(mktemp -t cssh-daemon.XXXXXX).png"
trap 'rm -f "$tmp_png"' EXIT
last_hash=""
notify "watching clipboard -> $REMOTE"
while true; do
    if extract_clipboard_png "$tmp_png"; then
        current_hash="$(hash_file "$tmp_png")"
        if [ "$current_hash" != "$last_hash" ]; then
            push_png_to_remote "$tmp_png"; last_hash="$current_hash"; notify "image synced"
        fi
    fi
    sleep "$poll_seconds"
done
CSSH_DAEMON_EOF
}

emit_plist() {
cat <<'CSSH_PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.cssh.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__HOME__/.cssh/bin/cssh-daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>__HOME__/.cssh/daemon.log</string>
    <key>StandardErrorPath</key><string>__HOME__/.cssh/daemon.log</string>
</dict>
</plist>
CSSH_PLIST_EOF
}

# ----------------------------------------------------------------------------
# SSH config parsing / editing
# ----------------------------------------------------------------------------
ssh_config="$HOME/.ssh/config"

list_ssh_hosts() {
    [ -f "$ssh_config" ] || return 0
    # Emit each concrete Host alias (skip wildcard patterns).
    awk 'tolower($1)=="host"{for(i=2;i<=NF;i++) if($i !~ /[*?]/) print $i}' "$ssh_config" | sort -u
}

ensure_controlmaster() {
    local host="$1"
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if grep -qE "ControlPath .*cm-cssh" "$ssh_config" 2>/dev/null && \
       awk -v h="$host" 'tolower($1)=="host"{f=0; for(i=2;i<=NF;i++) if($i==h) f=1} f&&/cssh/{print}' "$ssh_config" 2>/dev/null | grep -q .; then
        return 0
    fi
    cat >> "$ssh_config" <<CFG

# cssh: warm shared connection to $host for near-zero-latency pushes
Host $host
  ControlMaster auto
  ControlPath ~/.ssh/cm-cssh-%r@%h:%p
  ControlPersist 10m
CFG
    ok "enabled SSH multiplexing for $host"
}

add_custom_host() {
    local alias hostname user port identity
    alias="$(ui_input 'Host alias (what you type after ssh):' 'my-remote')"
    [ -n "$alias" ] || die "no alias given"
    hostname="$(ui_input 'Hostname or IP:' 'example.com')"
    user="$(ui_input 'SSH user:' "$USER")"
    port="$(ui_input 'Port [22]:' '22')"
    identity="$(ui_input 'IdentityFile (blank = default):' '')"
    [ -z "$port" ] && port=22
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    {
        printf '\n# cssh: custom host\nHost %s\n  HostName %s\n  User %s\n  Port %s\n' \
            "$alias" "$hostname" "$user" "$port"
        [ -n "$identity" ] && printf '  IdentityFile %s\n' "$identity"
        printf '  ControlMaster auto\n  ControlPath ~/.ssh/cm-cssh-%%r@%%h:%%p\n  ControlPersist 10m\n'
    } >> "$ssh_config"
    ok "added Host $alias to $ssh_config"
    printf '%s' "$alias"
}

# ----------------------------------------------------------------------------
# install steps
# ----------------------------------------------------------------------------
install_local_bin() {
    local bin_dir="$HOME/.cssh/bin"
    mkdir -p "$bin_dir"
    emit_lib    > "$bin_dir/cssh-lib.sh"
    emit_push   > "$bin_dir/cssh-push";   chmod 755 "$bin_dir/cssh-push"
    emit_daemon > "$bin_dir/cssh-daemon"; chmod 755 "$bin_dir/cssh-daemon"
    ok "installed local scripts -> $bin_dir"
}

write_config() {
    local primary="$1"
    local config_file="$HOME/.cssh/config"
    cat > "$config_file" <<CFG
REMOTE=$primary
REMOTE_IMAGE=.cssh/latest.png
CFG
    ok "default push target: $primary  ($config_file)"
}

install_remote() {
    local host="$1"
    info "installing shim on $host ..."
    emit_shim | ssh "$host" 'mkdir -p ~/.cssh/bin && cat > ~/.cssh/bin/xclip && chmod 755 ~/.cssh/bin/xclip' \
        || { warn "could not reach $host over SSH — skipped"; return 1; }
    ssh "$host" 'bash -s' <<'REMOTE_RC'
set -e
case "${SHELL:-}" in
  *zsh) rc="$HOME/.zshrc" ;;
  *bash) rc="$HOME/.bashrc" ;;
  *) rc="$HOME/.profile" ;;
esac
line='export PATH="$HOME/.cssh/bin:$PATH"'
grep -qF "$line" "$rc" 2>/dev/null || printf '\n# cssh: shim xclip ahead of the real one\n%s\n' "$line" >> "$rc"
REMOTE_RC
    ok "shim installed on $host  (relaunch Claude Code there to pick up PATH)"
}

setup_daemon_autostart() {
    local plist="$HOME/Library/LaunchAgents/com.cssh.daemon.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    emit_plist | sed "s|__HOME__|$HOME|g" > "$plist"
    launchctl unload "$plist" >/dev/null 2>&1 || true
    launchctl load "$plist" && ok "daemon auto-starts at login (launchctl)"
}

# ----------------------------------------------------------------------------
# uninstall — reverse everything the installer did, on both ends
# ----------------------------------------------------------------------------
uninstall_remote() {
    local host="$1"
    info "cleaning $host ..."
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" 'bash -s' <<'REMOTE_UNINSTALL'
set -e
# Drop the cssh PATH line (and its comment) from whichever rc files have it.
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    grep -q '^# cssh: shim xclip' "$rc" 2>/dev/null || continue
    tmp="$(mktemp)"
    awk 'c{c=0;next} /^# cssh: shim xclip/{c=1;next} {print}' "$rc" > "$tmp" && mv "$tmp" "$rc"
done
rm -rf "$HOME/.cssh"
REMOTE_UNINSTALL
    then ok "removed shim from $host"
    else warn "could not reach $host — delete ~/.cssh and the cssh PATH line there by hand"
    fi
}

strip_ssh_config() {
    [ -f "$ssh_config" ] || return 0
    grep -q '^# cssh' "$ssh_config" 2>/dev/null || { info "no cssh blocks in ~/.ssh/config"; return 0; }
    cp "$ssh_config" "$ssh_config.cssh.bak"
    local tmp; tmp="$(mktemp)"
    # A cssh block is a "# cssh" comment, its Host line, and the indented body
    # under it, ending at the next blank line.
    awk '
        /^# cssh/                  { skip=1; next }
        skip && /^Host[[:space:]]/ { next }
        skip && /^[[:space:]]*$/   { skip=0; next }
        skip && /^[[:space:]]/     { next }
        { skip=0; print }
    ' "$ssh_config" > "$tmp" && mv "$tmp" "$ssh_config"
    ok "removed cssh blocks from ~/.ssh/config  (backup: ~/.ssh/config.cssh.bak)"
}

uninstall() {
    local assume_yes=0
    case "${1:-}" in -y|--yes|yes) assume_yes=1 ;; esac

    banner
    step "Uninstall cssh"

    # Which remotes did we touch? Prefer the recorded list; fall back to the
    # hosts tagged with cssh blocks in ~/.ssh/config.
    local uhosts=() line
    if [ -f "$HOME/.cssh/hosts" ]; then
        while IFS= read -r line; do [ -n "$line" ] && uhosts+=("$line"); done < "$HOME/.cssh/hosts"
    elif [ -f "$ssh_config" ]; then
        while IFS= read -r line; do [ -n "$line" ] && uhosts+=("$line"); done \
            < <(awk '/^# cssh/{f=1;next} f&&tolower($1)=="host"{for(i=2;i<=NF;i++)print $i; f=0}' "$ssh_config" | sort -u)
    fi

    if [ "${#uhosts[@]}" -gt 0 ]; then
        info "remote shim will be removed from: ${bold}${uhosts[*]}${reset}"
    fi
    info "local: ~/.cssh, the login daemon, and cssh blocks in ~/.ssh/config"
    if [ "$assume_yes" != "1" ]; then
        ui_confirm "Remove all of it?" || die "cancelled — nothing changed"
    fi

    # 1) remote shims (best effort — a host may be offline).
    if [ "${#uhosts[@]}" -gt 0 ]; then
        step "Removing remote shim over SSH"
        local h
        for h in "${uhosts[@]}"; do uninstall_remote "$h"; done
    fi

    # 2) stop the daemon everywhere it might be running.
    step "Removing local components"
    pkill -f "\.cssh/bin/cssh-daemon" >/dev/null 2>&1 || true
    local plist="$HOME/Library/LaunchAgents/com.cssh.daemon.plist"
    if [ -f "$plist" ]; then
        launchctl unload "$plist" >/dev/null 2>&1 || true
        rm -f "$plist"
        ok "removed launchd agent"
    fi

    # 3) local files.
    rm -rf "$HOME/.cssh"
    ok "removed ~/.cssh"

    # 4) ssh config blocks.
    strip_ssh_config

    printf '\n%s%s cssh uninstalled.%s\n' "$green" "$bold" "$reset"
    info "If you bound a hotkey to cssh-push, remove that binding in your launcher."
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
main() {
    # Subcommand: uninstall (works with `... | bash -s -- --uninstall`).
    case "${1:-}" in
        uninstall|--uninstall|-u|remove|--remove) shift 2>/dev/null || true; uninstall "$@"; return ;;
    esac

    banner
    case "$(uname -s)" in
        Darwin|Linux) : ;;
        *) warn "this installer targets macOS/Linux laptops; continuing anyway" ;;
    esac
    have ssh || die "ssh not found"

    maybe_install_gum

    step "Choose which SSH host(s) to enable"
    # Portable array reads (macOS ships bash 3.2, which has no mapfile).
    local hosts=() chosen=() line
    while IFS= read -r line; do [ -n "$line" ] && hosts+=("$line"); done < <(list_ssh_hosts)
    if [ "${#hosts[@]}" -gt 0 ]; then
        while IFS= read -r line; do [ -n "$line" ] && chosen+=("$line"); done \
            < <(ui_choose_multi "Hosts from ~/.ssh/config — press x/space to select, then enter" "${hosts[@]}" "➕ Add a custom host")
    else
        info "no hosts found in ~/.ssh/config"
        chosen=("➕ Add a custom host")
    fi

    # bash 3.2 (macOS default) treats "${empty[@]}" as unbound under `set -u`,
    # so guard before iterating. An empty selection means the user picked nothing.
    [ "${#chosen[@]}" -gt 0 ] || die "no host selected — press x or space to toggle a host, then enter to confirm"

    local enabled=()
    local h
    for h in "${chosen[@]}"; do
        if [ "$h" = "➕ Add a custom host" ]; then
            local new_host; new_host="$(add_custom_host)"
            enabled+=("$new_host")
        else
            ensure_controlmaster "$h"
            enabled+=("$h")
        fi
    done
    [ "${#enabled[@]}" -gt 0 ] || die "no host selected — press x or space to toggle a host, then enter to confirm"

    step "Installing local components"
    install_local_bin

    step "Installing remote shim over SSH"
    local reachable=()
    for h in "${enabled[@]}"; do
        if install_remote "$h"; then reachable+=("$h"); fi
    done
    [ "${#reachable[@]}" -gt 0 ] || die "no host was reachable; nothing installed remotely"

    # Pick the default push target.
    local primary="${reachable[0]}"
    if [ "${#reachable[@]}" -gt 1 ]; then
        step "Which host should be the default push target?"
        primary="$(ui_choose_one "Default host for cssh-push / daemon" "${reachable[@]}")"
    fi
    write_config "$primary"
    # Record the hosts we touched so uninstall can clean them precisely.
    printf '%s\n' "${enabled[@]}" > "$HOME/.cssh/hosts"

    step "How do you want to trigger pushes?"
    local mode
    mode="$(ui_choose_one "Trigger mode" \
        "Auto-sync daemon (just screenshot, then Ctrl+V)" \
        "Hotkey / on-demand (run cssh-push)" \
        "Both")"
    case "$mode" in
        Auto-sync*|Both*)
            if [ "$(uname -s)" = "Darwin" ]; then
                setup_daemon_autostart
            else
                info "run the daemon with: ~/.cssh/bin/cssh-daemon"
            fi
            ;;
    esac

    # Warm the connection so the first real push is instant.
    ssh -o BatchMode=yes "$primary" true >/dev/null 2>&1 || true

    printf '\n%s%s All set.%s\n' "$green" "$bold" "$reset"
    info "Hotkey: bind a key to  ${bold}$HOME/.cssh/bin/cssh-push${reset}  (Raycast / Hammerspoon / Shortcuts)"
    info "Then: screenshot → Ctrl+V inside Claude Code on ${bold}$primary${reset}"
    warn "Relaunch Claude Code on the remote so it inherits the shimmed PATH."
    printf '  %s•%s uninstall anytime: %scurl -fsSL %s | bash -s -- --uninstall%s\n' \
        "$blue" "$reset" "$dim" "https://raw.githubusercontent.com/Hackerbone/cssh/main/install.sh" "$reset"
}

main "$@"
