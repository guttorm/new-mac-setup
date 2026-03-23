#!/bin/bash
# ============================================================================
# New Mac Migration Script — generated 2026-03-14 by Huginn 🪶
#
# Connects to old Mac via Thunderbolt networking, pulls all data and configs,
# installs apps, and configures the system.
#
# Usage:
#   chmod +x new-mac-setup.sh
#   ./new-mac-setup.sh                    # full run
#   ./new-mac-setup.sh --from 5           # resume from phase 5
#   ./new-mac-setup.sh --skip 3,7         # skip phases 3 and 7
#   ./new-mac-setup.sh --list             # show all phases
#   ./new-mac-setup.sh --dry-run          # show what would happen
#
# Prerequisites:
#   - Thunderbolt cable between old and new Mac
#   - Remote Login (SSH) enabled on old Mac
#   - Signed into iCloud on new Mac
#   - Signed into App Store on new Mac
# ============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
OLD_USER="guttormaase"
NEW_USER="$USER"
STATE_FILE="$HOME/.migration-state"
LOG_FILE="$HOME/migration.log"
RSYNC_OPTS="-a --partial --progress --human-readable"
OLD_MAC=""  # discovered automatically

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Helpers -----------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
step() { echo -e "\n${GREEN}${BOLD}▸ Phase $1: $2${NC}" | tee -a "$LOG_FILE"; }
info() { echo -e "  ${BLUE}→${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "  ${YELLOW}⚠ $*${NC}" | tee -a "$LOG_FILE"; }
err()  { echo -e "  ${RED}✗ $*${NC}" | tee -a "$LOG_FILE"; }
ok()   { echo -e "  ${GREEN}✓ $*${NC}" | tee -a "$LOG_FILE"; }

phase_done() {
  echo "$1" >> "$STATE_FILE"
  ok "Phase $1 complete"
}

is_phase_done() {
  [ -f "$STATE_FILE" ] && grep -qx "$1" "$STATE_FILE"
}

should_skip() {
  local phase="$1"
  # Check if in skip list
  if [[ -n "${SKIP_PHASES:-}" ]]; then
    echo "$SKIP_PHASES" | tr ',' '\n' | grep -qx "$phase" && return 0
  fi
  # Check --from flag (overrides completed state for phases >= FROM_PHASE)
  if [[ -n "${FROM_PHASE:-}" ]] && [[ "$phase" -lt "$FROM_PHASE" ]]; then
    return 0
  fi
  # If --from is set and we're at or past that phase, ignore completed state
  if [[ -n "${FROM_PHASE:-}" ]] && [[ "$phase" -ge "$FROM_PHASE" ]]; then
    return 1
  fi
  # Check if already completed
  is_phase_done "$phase" && warn "Phase $phase already completed (skipping)" && return 0
  return 1
}

confirm() {
  local msg="$1"
  echo -en "  ${YELLOW}$msg [y/N]:${NC} "
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

remote() {
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$OLD_MAC" "$@"
}

remote_size() {
  # Get human-readable size of a remote path
  remote "du -sh '$1' 2>/dev/null | cut -f1" 2>/dev/null || echo "unknown"
}

pull() {
  local src="$1" dst="$2"
  info "Pulling: $src → $dst"
  mkdir -p "$(dirname "$dst")"
  if [[ "$DRY_RUN" == "true" ]]; then
    info "(dry run) rsync $RSYNC_OPTS $OLD_MAC:$src $dst"
  else
    rsync $RSYNC_OPTS -e "ssh -o StrictHostKeyChecking=no" "$OLD_MAC:$src" "$dst" 2>&1 | tail -3 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -eq 0 ]; then
      # Verify: compare file counts
      local remote_count local_count
      remote_count=$(remote "find '$src' -type f 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo "?")
      local_count=$(find "$dst" -type f 2>/dev/null | wc -l | tr -d ' ')
      ok "Done: $(basename "$src") ($local_count files transferred, $remote_count on source)"
    else
      err "Failed: $src (exit code $rc)"
      if ! confirm "Continue anyway?"; then
        exit 1
      fi
    fi
  fi
}

pull_with_size() {
  # Like pull, but queries live size from old Mac first
  local src="$1" dst="$2" label="$3"
  local size
  size=$(remote_size "$src")
  info "${BOLD}${label} (~${size})${NC}"
}

setup_ssh_key() {
  # Copy SSH key to old Mac so we don't need passwords for every rsync
  info "Setting up key-based SSH to avoid repeated password prompts..."
  if [ ! -f "$HOME/.ssh/id_ed25519.pub" ] && [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
    info "Generating SSH key..."
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -q
  fi
  local pubkey
  pubkey=$(cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || cat "$HOME/.ssh/id_rsa.pub" 2>/dev/null)
  info "Copying SSH key to old Mac (you'll need to enter your password once)..."
  ssh -o StrictHostKeyChecking=no "$OLD_MAC" "mkdir -p ~/.ssh && echo '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null
  if remote "echo ok" 2>/dev/null | grep -q ok; then
    ok "SSH key installed — no more password prompts"
  else
    warn "Key-based auth failed — you'll need to enter your password for each transfer"
  fi
}

# --- Parse Args --------------------------------------------------------------
SKIP_PHASES=""
FROM_PHASE=""
DRY_RUN="false"
LIST_ONLY="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip)   SKIP_PHASES="$2"; shift 2 ;;
    --from)   FROM_PHASE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --list)   LIST_ONLY="true"; shift ;;
    --reset)  rm -f "$STATE_FILE"; echo "State reset."; exit 0 ;;
    *)        echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Phase List --------------------------------------------------------------
PHASES=(
  "1:Xcode Command Line Tools"
  "2:Connect to old Mac via Thunderbolt"
  "3:Install Homebrew"
  "4:Install Homebrew packages (Brewfile)"
  "5:Restore app configs (Mackup)"
  "6:Transfer user data (Documents, Music, Pictures, etc.)"
  "7:Transfer Desktop"
  "8:Transfer custom fonts"
  "9:Transfer LaunchAgents"
  "10:Transfer keyboard text replacements"
  "11:Install npm global packages"
  "12:Install pipx packages"
  "13:Setup Ruby (rbenv)"
  "14:Setup Fish shell"
  "15:Install App Store apps"
  "16:Restore Dock layout"
  "17:Apply macOS preferences"
  "18:Setup OpenClaw"
  "19:Print manual steps"
)

if [[ "$LIST_ONLY" == "true" ]]; then
  echo -e "\n${BOLD}Migration Phases:${NC}"
  for p in "${PHASES[@]}"; do
    num="${p%%:*}"
    desc="${p#*:}"
    if is_phase_done "$num"; then
      echo -e "  ${GREEN}✓ $num. $desc${NC}"
    else
      echo -e "  ○ $num. $desc"
    fi
  done
  echo ""
  exit 0
fi

# =============================================================================
echo -e "${BOLD}"
echo "  ┌─────────────────────────────────────────┐"
echo "  │   🪶  New Mac Migration Script          │"
echo "  │       generated by Huginn               │"
echo "  └─────────────────────────────────────────┘"
echo -e "${NC}"
echo "" > "$LOG_FILE"
log "Migration started at $(date)"
log "State file: $STATE_FILE"
echo ""

# =============================================================================
# PHASE 1: Xcode Command Line Tools
# =============================================================================
if ! should_skip 1; then
  step 1 "Xcode Command Line Tools"
  if xcode-select -p &>/dev/null; then
    ok "Already installed"
  elif confirm "Install Xcode Command Line Tools?"; then
    info "Installing Xcode Command Line Tools..."
    xcode-select --install
    echo ""
    warn "A dialog will appear. Click 'Install' and wait for it to finish."
    echo -en "  ${YELLOW}Press Enter when installation is complete...${NC}"
    read -r
  else
    warn "Skipped"
  fi
  phase_done 1
fi

# =============================================================================
# PHASE 2: Connect to old Mac via Thunderbolt
# =============================================================================
if ! should_skip 2; then
  step 2 "Connect to old Mac via Thunderbolt"
  info "Searching for old Mac on Thunderbolt bridge..."

  # Thunderbolt networking creates a bridge interface
  # Look for link-local addresses on bridge/thunderbolt interfaces
  OLD_MAC=""

  # Method 1: Check for Thunderbolt Bridge interface and try auto-discovery
  TB_IF=$(networksetup -listallhardwareports 2>/dev/null | grep -A1 "Thunderbolt Bridge" | grep "Device" | awk '{print $2}')
  OLD_IP=""

  if [ -n "$TB_IF" ]; then
    info "Thunderbolt Bridge interface: $TB_IF"

    # Try to get peer IP from ARP table after pinging
    ping -c 1 -t 1 169.254.255.255 &>/dev/null || true
    sleep 1

    # Check ARP for link-local peers on the bridge interface
    CANDIDATE=$(arp -a -i "$TB_IF" 2>/dev/null | grep -oE '169\.254\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$CANDIDATE" ]; then
      info "Found peer at $CANDIDATE via ARP"
      # Try silent SSH first (works if keys already set up)
      if ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=yes "${OLD_USER}@${CANDIDATE}" "echo ok" &>/dev/null; then
        OLD_IP="$CANDIDATE"
        ok "Auto-discovered old Mac at $OLD_IP"
      else
        # ARP found it but SSH needs a password — offer it as default
        info "Peer found but SSH needs authentication (expected on first connect)."
        if confirm "Use $CANDIDATE as the old Mac's IP?"; then
          OLD_IP="$CANDIDATE"
        fi
      fi
    fi
  fi

  # Method 2: Manual entry if auto-discovery failed
  if [ -z "$OLD_IP" ]; then
    echo ""
    info "Could not auto-discover old Mac."
    info "To find the old Mac's IP:"
    info "  On OLD Mac: System Settings → Network → Thunderbolt Bridge → IP address"
    info "  Or run: ipconfig getifaddr \$(networksetup -listallhardwareports | grep -A1 'Thunderbolt Bridge' | grep Device | awk '{print \$2}')"
    echo ""
    echo -en "  ${BOLD}Enter the old Mac's IP address (or hostname): ${NC}"
    read -r OLD_IP
  fi

  OLD_MAC="${OLD_USER}@${OLD_IP}"
  info "Trying to connect to $OLD_MAC..."

  if remote "echo 'connected'" 2>/dev/null; then
    ok "Connected to old Mac!"

    # Verify it's the right machine
    REMOTE_HOSTNAME=$(remote "hostname" 2>/dev/null)
    info "Remote hostname: $REMOTE_HOSTNAME"
    if ! confirm "Is this the correct machine?"; then
      err "Aborted. Re-run and enter the correct IP."
      exit 1
    fi
  else
    err "Cannot connect to $OLD_MAC"
    info "Troubleshooting:"
    info "  1. Is the Thunderbolt cable plugged in?"
    info "  2. Is Remote Login enabled on old Mac? (System Settings → General → Sharing)"
    info "  3. Can you ping the old Mac? ping $OLD_IP"
    info "  4. Try SSH manually: ssh $OLD_MAC"
    echo ""
    if confirm "Retry?"; then
      exec "$0" --from 2
    fi
    exit 1
  fi

  # Setup key-based SSH to avoid repeated password prompts
  setup_ssh_key

  # Save connection info for later phases
  echo "OLD_MAC=$OLD_MAC" > "$HOME/.migration-connection"
  phase_done 2
else
  # Load saved connection
  if [ -f "$HOME/.migration-connection" ]; then
    source "$HOME/.migration-connection"
    info "Using saved connection: $OLD_MAC"
  fi
fi

# =============================================================================
# PHASE 3: Install Homebrew
# =============================================================================
if ! should_skip 3; then
  step 3 "Install Homebrew"
  if command -v brew &>/dev/null; then
    ok "Homebrew already installed"
  elif confirm "Install Homebrew?"; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    warn "Skipped — many later phases depend on Homebrew"
  fi
  phase_done 3
fi

# Make sure brew is in PATH for subsequent phases
eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true

# =============================================================================
# PHASE 4: Install Homebrew packages
# =============================================================================
if ! should_skip 4; then
  step 4 "Install Homebrew packages (Brewfile)"
  info "Pulling Brewfile from old Mac..."

  DEFERRED_BREWFILE="$HOME/Brewfile.deferred"

  if [[ "$DRY_RUN" != "true" ]]; then
    scp "$OLD_MAC:~/Brewfile" "$HOME/Brewfile" 2>/dev/null || \
    remote "brew bundle dump --file=-" > "$HOME/Brewfile" 2>/dev/null

    if [ -f "$HOME/Brewfile" ]; then
      # --- Batch-fetch friendly names for all formulae and casks ---
      # Build space-separated lists of tokens by type
      _brew_tokens=""
      _cask_tokens=""
      while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^brew\ +\"([^\"]+)\" ]]; then
          _brew_tokens="$_brew_tokens ${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^cask\ +\"([^\"]+)\" ]]; then
          _cask_tokens="$_cask_tokens ${BASH_REMATCH[1]}"
        fi
      done < "$HOME/Brewfile"

      _DESC_FILE=$(mktemp /tmp/brew-descs.XXXXXX)

      _brew_count=$(echo $_brew_tokens | wc -w | tr -d ' ')
      _cask_count=$(echo $_cask_tokens | wc -w | tr -d ' ')
      info "Found $_brew_count formulae and $_cask_count casks to look up."
      info "Loading package descriptions (falls back to names only if this fails)..."
      info "Errors logged to: $LOG_FILE"

      # Temporarily disable exit-on-error for description fetching
      set +e

      info "  Running brew update..."
      brew update 2>&1 | tail -5 | tee -a "$LOG_FILE"
      info "  brew update exit code: $?"
      
      # Batch: all formulae in one brew info call → token\tdesc
      if [ -n "$_brew_tokens" ]; then
        info "  Fetching descriptions for $_brew_count formulae..."
        _brew_json=$(mktemp /tmp/brew-json.XXXXXX)
        brew info --json=v2 $_brew_tokens > "$_brew_json" 2>> "$LOG_FILE"
        _brew_rc=$?
        info "  brew info (formulae) exit code: $_brew_rc, output size: $(wc -c < "$_brew_json" | tr -d ' ') bytes"
        if [ "$_brew_rc" -eq 0 ] && [ -s "$_brew_json" ]; then
          python3 -c "
import sys, json
d = json.load(open(sys.argv[1]))
for f in d.get('formulae', []):
    print(f['name'] + '\t' + (f.get('desc') or f['name']))
" "$_brew_json" >> "$_DESC_FILE" 2>> "$LOG_FILE"
          ok "Formula descriptions loaded ($(wc -l < "$_DESC_FILE" | tr -d ' ') entries)"
        else
          warn "Skipped formula descriptions (brew info failed with exit $_brew_rc)"
          warn "Check $LOG_FILE for details"
        fi
        rm -f "$_brew_json"
      fi

      # Batch: all casks in one brew info call → token\tname
      if [ -n "$_cask_tokens" ]; then
        info "  Fetching descriptions for $_cask_count casks..."
        _cask_json=$(mktemp /tmp/cask-json.XXXXXX)
        brew info --json=v2 --cask $_cask_tokens > "$_cask_json" 2>> "$LOG_FILE"
        _cask_rc=$?
        info "  brew info (casks) exit code: $_cask_rc, output size: $(wc -c < "$_cask_json" | tr -d ' ') bytes"
        if [ "$_cask_rc" -eq 0 ] && [ -s "$_cask_json" ]; then
          python3 -c "
import sys, json
d = json.load(open(sys.argv[1]))
for c in d.get('casks', []):
    names = c.get('name', [c['token']])
    print(c['token'] + '\t' + (names[0] if names else c['token']))
" "$_cask_json" >> "$_DESC_FILE" 2>> "$LOG_FILE"
          ok "Cask descriptions loaded"
        else
          warn "Skipped cask descriptions (brew info failed with exit $_cask_rc)"
          warn "Check $LOG_FILE for details"
        fi
        rm -f "$_cask_json"
      fi

      info "  Description file: $(wc -l < "$_DESC_FILE" | tr -d ' ') total entries loaded"

      # Re-enable exit-on-error
      set -e

      # Helper: look up description from the batch file
      _get_desc() {
        local token="$1"
        local desc
        desc=$(grep "^${token}	" "$_DESC_FILE" 2>/dev/null | head -1 | cut -f2-)
        echo "${desc:-$token}"
      }

      # --- Parse Brewfile into temp files (one field per line, indexed) ---
      _BF_DIR=$(mktemp -d /tmp/brewfile-picker.XXXXXX)
      _idx=0

      while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        _type="" ; _token="" ; _display=""
        if [[ "$line" =~ ^brew\ +\"([^\"]+)\" ]]; then
          _type="brew"; _token="${BASH_REMATCH[1]}"
          _display="$(_get_desc "$_token")"
        elif [[ "$line" =~ ^cask\ +\"([^\"]+)\" ]]; then
          _type="cask"; _token="${BASH_REMATCH[1]}"
          _display="$(_get_desc "$_token")"
        elif [[ "$line" =~ ^tap\ +\"([^\"]+)\" ]]; then
          _type="tap"; _token="${BASH_REMATCH[1]}"
          _display="Homebrew tap: $_token"
        elif [[ "$line" =~ ^mas\ +\"([^\"]+)\" ]]; then
          _type="mas"; _token="${BASH_REMATCH[1]}"
          _display="App Store: $_token"
        elif [[ "$line" =~ ^vscode\ +\"([^\"]+)\" ]]; then
          _type="vscode"; _token="${BASH_REMATCH[1]}"
          _display="VS Code ext: $_token"
        else
          _type="other"; _token="$line"
          _display="$line"
        fi

        echo "$line"     > "$_BF_DIR/$_idx.line"
        echo "$_type"    > "$_BF_DIR/$_idx.type"
        echo "$_token"   > "$_BF_DIR/$_idx.token"
        echo "$_display" > "$_BF_DIR/$_idx.display"
        _idx=$((_idx + 1))
      done < "$HOME/Brewfile"

      _total=$_idx
      info "Found $_total packages. Review each one:"
      echo ""
      echo -e "  ${BOLD}Controls:${NC} y = install, n = skip (defer), a = install ALL remaining, q = skip ALL remaining"
      echo ""

      _install_all="false"
      _skip_all="false"
      > "$HOME/Brewfile.selected"
      > "$DEFERRED_BREWFILE"

      _i=0
      while [ $_i -lt $_total ]; do
        _num=$((_i + 1))
        _type=$(cat "$_BF_DIR/$_i.type")
        _token=$(cat "$_BF_DIR/$_i.token")
        _display=$(cat "$_BF_DIR/$_i.display")
        _line=$(cat "$_BF_DIR/$_i.line")
        _type_badge=""

        case "$_type" in
          brew)   _type_badge="${BLUE}[formula]${NC}" ;;
          cask)   _type_badge="${GREEN}[app]${NC}" ;;
          tap)    _type_badge="${YELLOW}[tap]${NC}" ;;
          mas)    _type_badge="${YELLOW}[App Store]${NC}" ;;
          vscode) _type_badge="${YELLOW}[vscode]${NC}" ;;
        esac

        if [[ "$_install_all" == "true" ]]; then
          echo "$_line" >> "$HOME/Brewfile.selected"
          _i=$((_i + 1)); continue
        fi
        if [[ "$_skip_all" == "true" ]]; then
          echo "$_line" >> "$DEFERRED_BREWFILE"
          _i=$((_i + 1)); continue
        fi

        # Taps are almost always needed — auto-include
        if [[ "$_type" == "tap" ]]; then
          info "  ${_type_badge} ${_token} (auto-included)"
          echo "$_line" >> "$HOME/Brewfile.selected"
          _i=$((_i + 1)); continue
        fi

        echo -en "  ${BOLD}[$_num/$_total]${NC} ${_type_badge} ${BOLD}${_token}${NC}"
        if [[ "$_display" != "$_token" ]]; then
          echo -en " — ${_display}"
        fi
        echo -en " [y/n/a/q]: "
        read -r -n1 choice
        echo ""

        case "$choice" in
          y|Y) echo "$_line" >> "$HOME/Brewfile.selected" ;;
          n|N) echo "$_line" >> "$DEFERRED_BREWFILE" ;;
          a|A) echo "$_line" >> "$HOME/Brewfile.selected"; _install_all="true"; info "  → Installing all remaining packages" ;;
          q|Q) echo "$_line" >> "$DEFERRED_BREWFILE"; _skip_all="true"; info "  → Deferring all remaining packages" ;;
          *)   echo "$_line" >> "$HOME/Brewfile.selected" ;;
        esac
        _i=$((_i + 1))
      done

      # Cleanup temp files
      rm -rf "$_BF_DIR" "$_DESC_FILE"

      _install_count=$(wc -l < "$HOME/Brewfile.selected" | tr -d ' ')
      _defer_count=$(wc -l < "$DEFERRED_BREWFILE" | tr -d ' ')
      echo ""
      info "Selected: $_install_count to install, $_defer_count deferred"

      # Report deferred
      if [ "$_defer_count" -gt 0 ]; then
        info "Deferred packages saved to: $DEFERRED_BREWFILE"
        info "Install later with: brew bundle install --file=$DEFERRED_BREWFILE"
      fi

      # Install selected
      if [ "$_install_count" -gt 0 ]; then
        if confirm "Install $_install_count selected packages now?"; then
          brew bundle install --file="$HOME/Brewfile.selected" --no-lock 2>&1 | tee -a "$LOG_FILE" | tail -10
          ok "Selected packages installed"
        else
          warn "Skipped — run 'brew bundle install --file=$HOME/Brewfile.selected' later"
        fi
      fi
    else
      err "Could not get Brewfile from old Mac"
      warn "Run 'brew bundle dump' on old Mac, then re-run this phase"
    fi
  fi
  phase_done 4
fi

# =============================================================================
# PHASE 5: Restore app configs (Mackup)
# =============================================================================
if ! should_skip 5; then
  step 5 "Restore app configs (Mackup)"
  info "Mackup backs up app settings via iCloud Drive."
  info "Make sure you ran 'mackup backup' on the old Mac and iCloud has synced."
  echo ""

  if command -v mackup &>/dev/null; then
    # Ensure mackup config exists
    if [ ! -f "$HOME/.mackup.cfg" ]; then
      cat > "$HOME/.mackup.cfg" << 'MACKUP_CFG'
[storage]
engine = icloud
MACKUP_CFG
    fi

    info "Mackup restores app configs (dotfiles, prefs) from iCloud Drive."
    info "Make sure you ran 'mackup backup' on the old Mac and iCloud has synced."
    if confirm "Restore Mackup configs now?"; then
      mackup restore 2>&1 | tee -a "$LOG_FILE"
      ok "Mackup restore complete"
    else
      warn "Skipped — run 'mackup restore' manually when ready"
    fi
  else
    warn "Mackup not installed. Install with: brew install mackup"
    warn "Then run: mackup restore"
  fi
  phase_done 5
fi

# =============================================================================
# PHASE 6: Transfer user data
# =============================================================================
if ! should_skip 6; then
  step 6 "Transfer user data from old Mac"
  info "This transfers your files via Thunderbolt. Large folders may take a while."
  echo ""

  # --- Documents ---
  pull_with_size ~/Documents/ "$HOME/Documents/" "Documents"
  if confirm "Transfer ~/Documents?"; then
    pull ~/Documents/ "$HOME/Documents/"
  fi

  # --- Music ---
  pull_with_size ~/Music/ "$HOME/Music/" "Music (iTunes + UVI samples + music projects)"
  if confirm "Transfer ~/Music?"; then
    pull ~/Music/ "$HOME/Music/"
  fi

  # --- Pictures ---
  pull_with_size ~/Pictures/ "$HOME/Pictures/" "Pictures (Lightroom, Aperture, loose photos)"
  info "iCloud Photos library will re-sync separately."
  if confirm "Transfer ~/Pictures?"; then
    pull ~/Pictures/ "$HOME/Pictures/"
  fi

  # --- Sites ---
  pull_with_size ~/Sites/ "$HOME/Sites/" "Sites"
  if confirm "Transfer ~/Sites?"; then
    pull ~/Sites/ "$HOME/Sites/"
  fi

  # --- Movies ---
  pull_with_size ~/Movies/ "$HOME/Movies/" "Movies"
  if confirm "Transfer ~/Movies?"; then
    pull ~/Movies/ "$HOME/Movies/"
  fi

  # --- go ---
  pull_with_size ~/go/ "$HOME/go/" "Go workspace"
  if confirm "Transfer ~/go?"; then
    pull ~/go/ "$HOME/go/"
  fi

  # --- OneDrive ---
  pull_with_size ~/OneDrive/ "$HOME/OneDrive/" "OneDrive"
  if confirm "Transfer ~/OneDrive?"; then
    pull ~/OneDrive/ "$HOME/OneDrive/"
  fi

  # --- Spectrasonics samples (Omnisphere + Keyscape) ---
  pull_with_size "~/Library/Application Support/Spectrasonics/" "$HOME/Library/Application Support/Spectrasonics/" "Spectrasonics STEAM samples (Omnisphere + Keyscape, ~132GB)"
  info "These are NOT re-downloadable — must transfer from old Mac."
  if confirm "Transfer Spectrasonics samples?"; then
    pull "~/Library/Application Support/Spectrasonics/" "$HOME/Library/Application Support/Spectrasonics/"
  fi

  # --- .config (dotfiles not covered by Mackup) ---
  pull_with_size ~/.config/ "$HOME/.config/" "~/.config (zed, gh, nvim, op, etc.)"
  if confirm "Transfer ~/.config/?"; then
    pull ~/.config/ "$HOME/.config/"
  fi

  # --- Pianoteq 8 STAGE (not in App Store or Homebrew) ---
  info "${BOLD}Pianoteq 8 STAGE (~90MB total)${NC}"
  if confirm "Transfer Pianoteq app + presets + sound library?"; then
    pull "/Applications/Pianoteq 8 STAGE/" "/Applications/Pianoteq 8 STAGE/"
    pull "~/Library/Application Support/Modartt/" "$HOME/Library/Application Support/Modartt/"
    info "Note: /Library/Application Support/Modartt/ is root-owned — run on new Mac:"
    info "  sudo rsync -a $OLD_MAC:/Library/Application\\ Support/Modartt/ /Library/Application\\ Support/Modartt/"
    ok "Pianoteq transferred (activate license at modartt.com)"
  fi

  # --- 2FHey (not in App Store or Homebrew) ---
  info "${BOLD}2FHey app (from old Mac's Downloads)${NC}"
  if remote "test -f ~/Downloads/2FHey.zip && echo yes" 2>/dev/null | grep -q yes; then
    if confirm "Pull 2FHey.zip and install?"; then
      rsync $RSYNC_OPTS -e "ssh -o StrictHostKeyChecking=no" "$OLD_MAC:~/Downloads/2FHey.zip" /tmp/2FHey.zip 2>&1 | tail -1
      unzip -o /tmp/2FHey.zip -d /Applications/ 2>&1 | tail -1
      ok "2FHey installed to /Applications/"
    fi
  else
    warn "2FHey.zip not found in old Mac's Downloads — install manually from 2fhey.com"
  fi

  # --- System crontab ---
  info "${BOLD}System crontab${NC}"
  REMOTE_CRONTAB=$(remote "crontab -l 2>/dev/null" || true)
  if [ -n "$REMOTE_CRONTAB" ]; then
    echo "$REMOTE_CRONTAB" > /tmp/old-crontab.txt
    info "Found crontab with $(echo "$REMOTE_CRONTAB" | grep -c '[^ ]') entries:"
    echo "$REMOTE_CRONTAB" | sed 's/^/    /'
    if confirm "Install this crontab on new Mac?"; then
      crontab /tmp/old-crontab.txt
      ok "Crontab installed"
    fi
  else
    ok "No crontab on old Mac"
  fi

  # --- .githelpers and .gitignore_global ---
  info "${BOLD}Git dotfiles (.githelpers, .gitignore_global)${NC}"
  if confirm "Transfer git dotfiles?"; then
    for f in .githelpers .gitignore_global; do
      if remote "test -f ~/$f && echo yes" 2>/dev/null | grep -q yes; then
        rsync $RSYNC_OPTS -e "ssh -o StrictHostKeyChecking=no" "$OLD_MAC:~/$f" "$HOME/$f" 2>&1 | tail -1 | tee -a "$LOG_FILE"
        ok "Copied $f"
      fi
    done
  else
    warn "Skipped"
  fi

  # --- .openclaw (in case Mackup didn't cover it) ---
  info "${BOLD}~/.openclaw (OpenClaw workspace)${NC}"
  if [ -d "$HOME/.openclaw/workspace" ]; then
    ok "~/.openclaw already exists (likely from Mackup or iCloud)"
  elif confirm "Transfer ~/.openclaw from old Mac?"; then
    pull ~/.openclaw/ "$HOME/.openclaw/"
  else
    warn "Skipped"
  fi

  phase_done 6
fi

# =============================================================================
# PHASE 7: Transfer Desktop
# =============================================================================
if ! should_skip 7; then
  step 7 "Transfer Desktop"
  # Check if iCloud Desktop sync is already active on this Mac
  if defaults read ~/Library/Preferences/MobileMeAccounts.plist 2>/dev/null | grep -q "CLOUDDESKTOP"; then
    info "iCloud Desktop sync appears active on this Mac."
    info "Files should sync automatically. Skipping transfer to avoid duplicates."
    if confirm "Transfer anyway (overrides iCloud sync check)?"; then
      pull ~/Desktop/ "$HOME/Desktop/"
    else
      ok "Skipped — Desktop will sync via iCloud"
    fi
  else
    pull_with_size ~/Desktop/ "$HOME/Desktop/" "Desktop"
    if confirm "Transfer ~/Desktop?"; then
      pull ~/Desktop/ "$HOME/Desktop/"
    fi
  fi
  phase_done 7
fi

# =============================================================================
# PHASE 8: Transfer custom fonts
# =============================================================================
if ! should_skip 8; then
  step 8 "Transfer custom fonts"
  info "55 custom fonts on old Mac (0xProto, Berkeley Mono, IBM Plex, Consolas, etc.)"
  if confirm "Transfer ~/Library/Fonts/?"; then
    pull ~/Library/Fonts/ "$HOME/Library/Fonts/"
  fi
  phase_done 8
fi

# =============================================================================
# PHASE 9: Transfer LaunchAgents
# =============================================================================
if ! should_skip 9; then
  step 9 "Transfer LaunchAgents"
  info "LaunchAgents on old Mac:"
  info "  - ai.openclaw.gateway.plist"
  info "  - homebrew.mxcl.postgresql@17.plist"
  info "  - homebrew.mxcl.tronbyt-server.plist"
  info "  - jp.plentycom.boa.SteerMouse.plist"
  info "  - com.backblaze.bzbmenu.plist"
  info "  - (+ Google, Adobe, Steam — auto-recreated by apps)"
  echo ""
  info "Note: Homebrew service plists are recreated by 'brew services start'."
  info "      App-created plists are recreated when you open those apps."
  info "      Only custom/manual plists truly need copying."
  echo ""
  if confirm "Transfer ~/Library/LaunchAgents/?"; then
    pull ~/Library/LaunchAgents/ "$HOME/Library/LaunchAgents/"
  fi
  phase_done 9
fi

# =============================================================================
# PHASE 10: Transfer keyboard text replacements
# =============================================================================
if ! should_skip 10; then
  step 10 "Transfer keyboard text replacements"
  info "Text replacements sync via iCloud, but pulling as backup."
  if confirm "Transfer text replacements plist?"; then
    pull ~/Library/Preferences/.GlobalPreferences.plist \
         /tmp/old-global-prefs.plist
    # Extract just the text replacements
    if [[ "$DRY_RUN" != "true" ]]; then
      defaults import -g /tmp/old-global-prefs.plist 2>/dev/null || \
        warn "Could not import text replacements. These usually sync via iCloud."
    fi
  fi
  phase_done 10
fi

# =============================================================================
# PHASE 11: Install npm global packages
# =============================================================================
if ! should_skip 11; then
  step 11 "Install npm global packages"
  info "Will install these global npm packages:"
  info "  @openai/codex, @sourcegraph/amp, clawdhub, openclaw"
  if confirm "Install global npm packages?"; then
    if [[ "$DRY_RUN" != "true" ]]; then
      npm install -g @openai/codex 2>&1 | tail -2
      npm install -g @sourcegraph/amp 2>&1 | tail -2
      npm install -g clawdhub 2>&1 | tail -2
      npm install -g openclaw 2>&1 | tail -2
      ok "npm packages installed"
    fi
  else
    warn "Skipped — install manually later with: npm install -g <package>"
  fi
  phase_done 11
fi

# =============================================================================
# PHASE 12: Install pipx packages
# =============================================================================
if ! should_skip 12; then
  step 12 "Install pipx packages"
  if command -v pipx &>/dev/null; then
    info "Will install: argcomplete, markitdown"
    if confirm "Install pipx packages?"; then
      pipx install argcomplete 2>&1 | tail -1
      pipx install markitdown 2>&1 | tail -1
      ok "pipx packages installed"
    else
      warn "Skipped"
    fi
  else
    warn "pipx not installed — skipping"
  fi
  phase_done 12
fi

# =============================================================================
# PHASE 13: Setup Ruby (rbenv)
# =============================================================================
if ! should_skip 13; then
  step 13 "Setup Ruby via rbenv"
  if command -v rbenv &>/dev/null; then
    RUBY_VERSION="3.3.9"
    if ! rbenv versions 2>/dev/null | grep -q "$RUBY_VERSION"; then
      info "Will install Ruby $RUBY_VERSION via rbenv and set as global."
      if confirm "Install Ruby $RUBY_VERSION? (takes a few minutes to compile)"; then
        rbenv install "$RUBY_VERSION" 2>&1 | tail -3
        rbenv global "$RUBY_VERSION"
        ok "Ruby $RUBY_VERSION set as global"
      else
        warn "Skipped"
      fi
    else
      rbenv global "$RUBY_VERSION"
      ok "Ruby $RUBY_VERSION already installed, set as global"
    fi
  else
    warn "rbenv not installed — skipping Ruby setup"
  fi
  phase_done 13
fi

# =============================================================================
# PHASE 14: Setup Fish shell
# =============================================================================
if ! should_skip 14; then
  step 14 "Setup Fish shell"
  FISH_PATH="/opt/homebrew/bin/fish"
  if command -v fish &>/dev/null; then
    info "Will add fish to /etc/shells and set as default shell."
    if confirm "Set Fish as default shell?"; then
      if ! grep -q "$FISH_PATH" /etc/shells 2>/dev/null; then
        info "Adding fish to /etc/shells (needs sudo)"
        echo "$FISH_PATH" | sudo tee -a /etc/shells
      fi
      if [ "$SHELL" != "$FISH_PATH" ]; then
        info "Setting fish as default shell"
        chsh -s "$FISH_PATH"
      fi
      ok "Fish configured as default shell"
    else
      warn "Skipped — run 'chsh -s /opt/homebrew/bin/fish' later"
    fi
    info "Fish config was restored by Mackup in Phase 5."
    info "Note: remove the opam line from config.fish (opam is no longer installed)."
  else
    warn "Fish not installed — skipping"
  fi
  phase_done 14
fi

# =============================================================================
# PHASE 15: Install App Store apps
# =============================================================================
if ! should_skip 15; then
  step 15 "Install App Store apps"
  if command -v mas &>/dev/null; then
    info "Will install these App Store apps:"

    MAS_APPS=(
      "1569813296:1Password for Safari"
      "937984704:Amphetamine"
      "411643860:DaisyDisk"
      "640199958:Developer"
      "1358823008:Flighty"
      "1622835804:Kagi Search"
      "409183694:Keynote"
      "409203825:Numbers"
      "409201541:Pages"
      "639968404:Parcel Classic"
      "1289583905:Pixelmator Pro"
      "1529448980:Reeder"
      "6448078074:Tapestry"
      "899247664:TestFlight"
      "425424353:The Unarchiver"
      "904280696:Things 3"
      "775737590:iA Writer"
    )

    for app_entry in "${MAS_APPS[@]}"; do
      app_name="${app_entry#*:}"
      info "  • $app_name"
    done
    echo ""
    if confirm "Install all these App Store apps?"; then
      for app_entry in "${MAS_APPS[@]}"; do
        app_id="${app_entry%%:*}"
        app_name="${app_entry#*:}"
        info "Installing $app_name..."
        mas install "$app_id" 2>&1 | tail -1 || warn "Failed: $app_name"
      done
    else
      warn "Skipped — install manually from the App Store"
    fi

    echo ""
    info "Skipped (install manually if needed):"
    info "  - Final Cut Pro (large download)"

    info "  - Aeronaut, Arco, Capo, Wallaroo"
    ok "App Store apps installed"
  else
    warn "mas not installed — install App Store apps manually"
  fi
  phase_done 15
fi

# =============================================================================
# PHASE 16: Restore Dock layout
# =============================================================================
if ! should_skip 16; then
  step 16 "Restore Dock layout"
  info "Will pull your Dock layout from the old Mac and apply it."
  if confirm "Restore Dock layout from old Mac?"; then
    if [[ "$DRY_RUN" != "true" ]]; then
      scp "$OLD_MAC:~/Library/Preferences/com.apple.dock.plist" /tmp/old-dock.plist 2>/dev/null
      if [ -f /tmp/old-dock.plist ]; then
        defaults import com.apple.dock /tmp/old-dock.plist
        killall Dock 2>/dev/null || true
        ok "Dock layout restored"
      else
        warn "Could not pull Dock plist — set up manually"
      fi
    fi
  else
    warn "Skipped — arrange your Dock manually"
  fi
  phase_done 16
fi

# =============================================================================
# PHASE 17: Apply macOS preferences
# =============================================================================
if ! should_skip 17; then
  step 17 "Apply macOS preferences"

  info "Will apply these macOS preferences:"
  info "  • Finder: show hidden files, path bar, status bar"
  info "  • Keyboard: disable press-and-hold, fast key repeat"
  if confirm "Apply macOS preferences?"; then
    # Show hidden files in Finder
    defaults write com.apple.finder AppleShowAllFiles -bool true
    # Show path bar in Finder
    defaults write com.apple.finder ShowPathbar -bool true
    # Show status bar in Finder
    defaults write com.apple.finder ShowStatusBar -bool true
    # Disable press-and-hold for keys (enable key repeat)
    defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
    # Fast key repeat rate
    defaults write NSGlobalDomain KeyRepeat -int 2
    defaults write NSGlobalDomain InitialKeyRepeat -int 15

    # Restart Finder to apply
    killall Finder 2>/dev/null || true

    ok "macOS preferences applied"
  else
    warn "Skipped — apply manually in System Settings"
  fi
  phase_done 17
fi

# =============================================================================
# PHASE 18: Setup OpenClaw
# =============================================================================
if ! should_skip 18; then
  step 18 "Setup OpenClaw"
  if command -v openclaw &>/dev/null; then
    info "OpenClaw workspace was transferred in Phase 6 (inside ~/.openclaw via Documents or Mackup)."
    info "If ~/.openclaw didn't come over, pull it manually:"
    info "  rsync -a $OLD_MAC:~/.openclaw/ ~/.openclaw/"
    echo ""
    # Ensure workspace exists
    if [ ! -d "$HOME/.openclaw" ]; then
      if confirm "Transfer ~/.openclaw from old Mac?"; then
        pull ~/.openclaw/ "$HOME/.openclaw/"
      fi
    fi
    if confirm "Start OpenClaw gateway?"; then
      if [[ "$DRY_RUN" != "true" ]]; then
        openclaw gateway start 2>&1 | tail -3 || warn "Gateway start failed — check 'openclaw status'"
      fi
      ok "OpenClaw configured"
    else
      warn "Skipped — start later with: openclaw gateway start"
    fi
  else
    warn "OpenClaw not installed. Install with: npm install -g openclaw"
  fi
  phase_done 18
fi

# =============================================================================
# PHASE 19: Manual steps
# =============================================================================
if ! should_skip 19; then
  step 19 "Manual steps remaining"
  echo ""
  echo -e "${BOLD}  ┌──────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}  │  BEFORE WIPING OLD MAC — Sign out of these services:        │${NC}"
  echo -e "${BOLD}  ├──────────────────────────────────────────────────────────────┤${NC}"
  echo -e "  │  • ${RED}iCloud${NC} — System Settings → Apple ID → Sign Out"
  echo -e "  │  • ${RED}iMessage${NC} — Messages → Settings → iMessage → Sign Out"
  echo -e "  │  • ${RED}Music/iTunes${NC} — Account → Authorizations → Deauthorize"
  echo -e "  │  • ${RED}Adobe apps${NC} — Sign out in any Adobe app"
  echo -e "  │  • ${RED}iLok licenses${NC} — Open iLok License Manager:"
  echo -e "  │      1. Sign in at ilok.com"
  echo -e "  │      2. Go to Licenses tab"
  echo -e "  │      3. Select Keyscape/Omnisphere licenses"
  echo -e "  │      4. Deactivate from old Mac"
  echo -e "  │      5. On NEW Mac: install iLok Manager, sign in, activate"
  echo -e "${BOLD}  └──────────────────────────────────────────────────────────────┘${NC}"
  echo ""
  echo -e "${BOLD}  Apps to install manually:${NC}"
  echo "  ──────────────────────────────────────────────────────"
  echo "  • Adobe Lightroom   — open Creative Cloud (installed via Brewfile) → install Lightroom"
  echo "  • 2FHey             — pulled from old Mac (see below)"
  echo ""
  echo -e "  ${BOLD}Apps installed via Brewfile — enter license keys from 1Password:${NC}"
  echo "  • Alfred 5, Bartender 6, AlDente, Affinity Photo 2, Keyboard Maestro"
  echo ""
  echo -e "  ${BOLD}Roland USB/MIDI drivers:${NC}"
  echo "  • Installer transferred in ~/Music/A-SeriesKeyboardUSBDriver/"
  echo "  • Run: sudo installer -pkg ~/Music/A-SeriesKeyboardUSBDriver/A-SeriesKeyboard_USBDriver11.pkg -target /"
  echo ""
  echo -e "  ${YELLOW}Music production (do last — large downloads + license transfer):${NC}"
  echo "  • iLok License Manager — https://ilok.com"
  echo "  •   → Sign in, activate Keyscape + Omnisphere licenses on new Mac"
  echo "  • Keyscape           — download from spectrasonics.net"
  echo "  • Omnisphere         — download from spectrasonics.net"
  echo "  • UVIWorkstation     — https://uvi.net (samples transferred in Phase 6)"
  echo ""
  echo -e "  ${BOLD}Grant permissions (System Settings → Privacy & Security):${NC}"
  echo "  • Accessibility: Alfred, Keyboard Maestro, Bartender, OpenClaw"
  echo "  • Screen Recording: Peekaboo, OpenClaw"
  echo "  • Full Disk Access: Hazel, OpenClaw, Fish, Terminal/Ghostty"
  echo "  • Input Monitoring: SteerMouse, Keyboard Maestro"
  echo ""
  echo -e "  ${BOLD}Steam games:${NC}"
  echo "  • Install Steam (via Brewfile or steam.com), sign in"
  echo "  • Balatro + other games will be available to re-download"
  echo ""
  echo -e "  ${BOLD}Services to start:${NC}"
  echo "  • brew services start postgresql@17"
  echo "  • brew services start tronbyt-server"
  echo "  • openclaw gateway start"
  echo ""
  echo -e "  ${BOLD}Backblaze:${NC}"
  echo "  • Install from https://backblaze.com — will start a fresh backup"
  echo ""
  phase_done 19
fi

# =============================================================================
# DONE
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Migration complete! 🪶${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Log: $LOG_FILE"
echo "  State: $STATE_FILE (delete to re-run all phases)"
echo ""
echo "  To re-run a specific phase:"
echo "    $0 --from <phase_number>"
echo ""
echo "  To reset and start over:"
echo "    $0 --reset"
echo ""
