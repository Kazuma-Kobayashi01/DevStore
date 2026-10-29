#!/bin/sh
# Builds release and installs DevStore.app to /Applications, devstore + devstore-mcp to ~/.local/bin.
# Quit the app first; the MCP registration already points at ~/.local/bin/devstore-mcp.
set -eu
cd "$(dirname "$0")/.."
scripts/build-app.sh
if pgrep -f "/Applications/DevStore.app/Contents/MacOS/DevStore" >/dev/null; then
  echo "DevStore.app is running in /Applications; quit it first" >&2; exit 1
fi
rm -rf /Applications/DevStore.app
ditto build/DevStore.app /Applications/DevStore.app
codesign --verify --deep --strict /Applications/DevStore.app
mkdir -p "$HOME/.local/bin"
install -m 0755 .build/release/devstore .build/release/devstore-mcp "$HOME/.local/bin/"
echo "installed /Applications/DevStore.app and ~/.local/bin/{devstore,devstore-mcp}"
