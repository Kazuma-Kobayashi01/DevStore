#!/bin/sh
# Installs the devstore Skill and registers the devstore MCP server for Claude Code and Codex.
# Requires ~/.local/bin/devstore-mcp (scripts/install.sh). Re-runnable.
set -eu
cd "$(dirname "$0")/.."
MCP="$HOME/.local/bin/devstore-mcp"
[ -x "$MCP" ] || { echo "missing $MCP; run scripts/install.sh first" >&2; exit 1; }

for dir in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
  mkdir -p "$dir/devstore"
  cp skills/devstore/SKILL.md "$dir/devstore/SKILL.md"
  echo "skill -> $dir/devstore"
done

if command -v claude >/dev/null; then
  if claude mcp get devstore >/dev/null 2>&1; then echo "claude: devstore MCP already registered"
  else claude mcp add --scope user devstore -- "$MCP"; fi
fi

if command -v codex >/dev/null; then
  if codex mcp get devstore >/dev/null 2>&1; then echo "codex: devstore MCP already registered"
  else
    cp -p "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.devstore-backup" 2>/dev/null || true
    codex mcp add devstore -- "$MCP"
  fi
fi
