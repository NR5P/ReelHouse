#!/usr/bin/env bash
# Installs the ReelHouse server on Linux (Debian/Ubuntu/Raspberry Pi OS): installs .NET 10 and
# ffmpeg if they are missing, builds the server, and runs it as the systemd unit "reelhouse",
# which restarts on failure and at boot. Run it from a checkout, as the account ReelHouse should
# run as (not root); it asks for sudo when it needs it.
#
#   ./scripts/install-linux.sh                 # HTTP on 3350, HTTPS on 3453
#   HTTP_PORT=8096 ./scripts/install-linux.sh  # another HTTP port
#
# Updating later: git pull && ./scripts/install-linux.sh  (data/ is never touched).
#
# Torrent downloads ("+ Add") are a separate, optional step, because they install a VPN tunnel,
# qBittorrent and Prowlarr: sudo ./downloads/install-downloads.sh  - see docs/MOVIE_DOWNLOADS.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTTP_PORT="${HTTP_PORT:-3350}"
APP_USER="${APP_USER:-$(id -un)}"

[[ "$(id -u)" -ne 0 ]] || { echo "Run this as the account ReelHouse should run as, not as root." >&2; exit 1; }
[[ "$(uname -s)" == "Linux" ]] || { echo "This installer is for Linux. On a Mac or Windows, see README.md (Running it)." >&2; exit 1; }

missing=()
command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks 2>/dev/null | grep -q '^10\.' || missing+=("dotnet-sdk-10.0")
command -v ffmpeg >/dev/null 2>&1 || missing+=("ffmpeg")
if [[ ${#missing[@]} -gt 0 ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    echo "==> Installing: ${missing[*]}"
    sudo apt-get update
    if ! sudo apt-get install -y "${missing[@]}"; then
      # Older releases don't carry .NET 10 in their own archive: Microsoft's install script works anywhere.
      if [[ " ${missing[*]} " == *" dotnet-sdk-10.0 "* ]]; then
        echo "==> dotnet-sdk-10.0 isn't in this system's packages; using Microsoft's installer"
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
        sudo bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet
        sudo ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
        sudo apt-get install -y ffmpeg || true
      fi
    fi
  else
    echo "Please install: ${missing[*]} (no apt-get here to do it for you)." >&2
    exit 1
  fi
fi
command -v ffmpeg >/dev/null 2>&1 || echo "WARNING: ffmpeg is missing - movies won't play and music can't be converted." >&2
DOTNET_PATH="$(command -v dotnet)"

echo "==> Building"
dotnet build "$ROOT_DIR/ReelHouse.Server/ReelHouse.Server.csproj" -c Release

echo "==> Installing the reelhouse service (user $APP_USER, HTTP port $HTTP_PORT)"
sed -e "s|__APP_USER__|$APP_USER|g" -e "s|__INSTALL_DIR__|$ROOT_DIR|g" \
    -e "s|__DOTNET_PATH__|$DOTNET_PATH|g" -e "s|__HTTP_PORT__|$HTTP_PORT|g" \
    "$ROOT_DIR/systemd/reelhouse.service" | sudo tee /etc/systemd/system/reelhouse.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable reelhouse >/dev/null
sudo systemctl restart reelhouse

ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
systemctl --no-pager --lines=0 status reelhouse 2>/dev/null | grep -E "●|Active:" || true
echo
echo "ReelHouse is running. On a device on this network open:"
echo "  http://${ADDR:-this-machine}:$HTTP_PORT   (or https://${ADDR:-this-machine}:3453)"
echo "On a server with no accounts yet, the first visit asks you to create the admin account. The apps find the server on their own."
echo "Logs: journalctl -u reelhouse -f"
