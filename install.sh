#!/usr/bin/env bash
# ws installer
# Usage: curl -fsSL https://raw.githubusercontent.com/kangthink/ws/main/install.sh | bash

set -euo pipefail

REPO="https://github.com/kangthink/ws.git"
INSTALL_DIR="$HOME/.ws"
BIN_DIR="$HOME/bin"

info()  { printf "\033[1;34m[ws]\033[0m %s\n" "$1"; }
ok()    { printf "\033[1;32m[ws]\033[0m %s\n" "$1"; }
err()   { printf "\033[1;31m[ws]\033[0m %s\n" "$1" >&2; }

# ── Check OS ──────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  err "ws is macOS only."
  exit 1
fi

# ── Clone / Update repo ──────────────────────────────────────────
if [[ -d "$INSTALL_DIR" ]]; then
  info "Updating ws..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  info "Cloning ws..."
  git clone "$REPO" "$INSTALL_DIR"
fi

# ── Link CLI ──────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/ws" "$BIN_DIR/ws"
chmod +x "$BIN_DIR/ws"
ok "Linked ws -> $BIN_DIR/ws"

# ── Ensure ~/bin in PATH ─────────────────────────────────────────
add_to_path() {
  local shell_rc="$1"
  if [[ -f "$shell_rc" ]] && grep -q 'export PATH=.*\$HOME/bin' "$shell_rc"; then
    return
  fi
  printf '\n# ws\nexport PATH="$HOME/bin:$PATH"\n' >> "$shell_rc"
  ok "Added ~/bin to PATH in $(basename "$shell_rc")"
}

if [[ "$SHELL" == */zsh ]]; then
  add_to_path "$HOME/.zshrc"
elif [[ "$SHELL" == */bash ]]; then
  add_to_path "$HOME/.bashrc"
fi

# ── Done ──────────────────────────────────────────────────────────
echo ""
ok "ws installed!"
echo ""
info "Usage:"
echo "  ws status              # workspace summary"
echo "  ws clean --dry-run     # preview reclaimable space"
echo "  ws clean               # clean stale dependencies"
echo ""
