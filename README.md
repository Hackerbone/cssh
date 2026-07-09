# cssh

**Paste local clipboard images into Claude Code over SSH.** Screenshot on your
laptop, press <kbd>Ctrl</kbd>+<kbd>V</kbd> in a remote Claude Code session, done.

Claude Code runs on a remote box and reads the *remote's* clipboard, so a normal
paste never sees the screenshot sitting in your *laptop's* clipboard. `cssh`
bridges the two.

## Install

One line, on your laptop:

```bash
curl -fsSL https://raw.githubusercontent.com/Hackerbone/cssh/main/install.sh | bash
```

The installer reads `~/.ssh/config`, lets you pick which host(s) to enable (or
add a new one), and sets everything up on both ends. Zero runtime dependencies
beyond `bash` and `ssh`. It uses [`gum`](https://github.com/charmbracelet/gum)
for the menus when available, and falls back to a clean built-in menu otherwise.

## Usage

1. Copy or screenshot an image.
2. **Daemon mode:** nothing to do. **Hotkey mode:** press your bound key.
3. In Claude Code on the remote, press <kbd>Ctrl</kbd>+<kbd>V</kbd>.

Bind the hotkey to `~/.cssh/bin/cssh-push` with Raycast, Hammerspoon, macOS
Shortcuts, or Karabiner.

## How it works

Claude Code reads pasted images on Linux by shelling out to `xclip` (verified
against the Claude Code binary):

```
xclip -selection clipboard -t TARGETS   -o    # is an image available?
xclip -selection clipboard -t image/png -o    # give me the PNG
```

- **Remote** — a tiny `xclip` shim, placed ahead of the real one on `PATH`. When
  a fresh image is waiting at `~/.cssh/latest.png` it serves it to those calls;
  otherwise it delegates to the real `xclip`. The image is one-shot (served once,
  then deleted) with a TTL guard, so your next paste is normal text. No X server,
  no Xvfb, no OSC 52.
- **Local** — reads the image from your OS clipboard (macOS `osascript`, Wayland
  `wl-paste`, X11 `xclip`, Windows PowerShell) and ships the bytes to the remote
  over a multiplexed SSH connection (a warm socket, so pushes are near-instant).

Two ways to trigger the push, chosen at install — use either or both:

- **Daemon** — auto-syncs every new clipboard image. Just screenshot, then paste.
- **Hotkey** — runs `cssh-push` on demand.

## Configuration

| Setting | Location | Default |
| --- | --- | --- |
| Default push target | `~/.cssh/config` → `REMOTE` | chosen at install |
| Per-push override | `cssh-push <host>` | — |
| Image TTL (remote) | `~/.cssh/ttl` (seconds) | `300` |
| Daemon poll interval | `CSSH_POLL_SECONDS` | `1` |

## Requirements

- **Laptop** — macOS, Linux (X11/Wayland), or Windows via WSL/Git-Bash; `bash` + `ssh`.
- **Remote** — any Linux box you SSH into; the shim needs only `bash`, `stat`, `date`.

## Uninstall

```bash
# laptop
rm -rf ~/.cssh
launchctl unload ~/Library/LaunchAgents/com.cssh.daemon.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.cssh.daemon.plist

# remote (per host)
ssh <host> 'rm -f ~/.cssh/bin/xclip'
```

Then remove the `# cssh` blocks from `~/.ssh/config` on the laptop and the
`# cssh` `PATH` line from your remote shell rc.

## License

MIT
