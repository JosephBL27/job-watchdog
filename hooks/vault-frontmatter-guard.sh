#!/usr/bin/env bash
# vault-frontmatter-guard.sh — PostToolUse advisory guard for Obsidian vault markdown.
#
# WHY RUBY AND NOT PYTHON: PyYAML raises ConstructorError on `key: {{PLACEHOLDER}}`
# ("found unhashable key") while Ruby Psych and Obsidian's own js-yaml both ACCEPT
# it. A PyYAML guard therefore reports phantom breaks. Calibrated 2026-09-22
# against the live plugin: notes PyYAML called broken, Obsidian read fine.
#
# TWO PATH SHAPES, both required (2026-09-22 rewrite):
#   Write/Edit/MultiEdit -> tool_input.file_path, ABSOLUTE
#   mcp__obsidian__vault_write|vault_append|vault_patch -> tool_input.path, RELATIVE
#     to the vault root (verified against the live tool schemas). The first version
#     of this guard read only file_path, so every MCP write exited 0 with no output
#     while looking healthy. That is this vault's signature failure class.
#
# Exits 0 ALWAYS. Advisory: it reports, it never blocks. The weekly headless
# `claude --agent brain-steward` run therefore cannot be starved by it.
set -uo pipefail

export VAULT="${VAULT_PATH:-$HOME/vault}"
VAULT_NAME="$(basename "$VAULT")"

INPUT="$(cat)"

# --- fast gate, pure bash, BEFORE spawning any interpreter ---------------------
# Cheap substring test on the raw payload. Anything not plausibly a vault write
# leaves here in ~3ms instead of paying for a python3 start.
case "$INPUT" in
  *"$VAULT_NAME"*|*mcp__obsidian__vault_*) ;;
  *) exit 0 ;;
esac

FILE="$(printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json,sys,os
VAULT=os.environ["VAULT"]
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
ti=d.get("tool_input") or {}
p = ti.get("file_path") or ti.get("path") or ""
if not isinstance(p,str) or not p:
    print(""); raise SystemExit
# MCP paths are vault-relative; native tool paths are absolute.
if not p.startswith("/"):
    p = os.path.join(VAULT, p)
print(p)
' 2>/dev/null)"

case "$FILE" in
  "$VAULT"/*.md) ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0

case "$FILE" in
  *"/40 Archives/_"*|*"/.obsidian/"*|*"/tmp/"*) exit 0 ;;
esac

command -v ruby >/dev/null 2>&1 || {
  printf '%s\n' '{"systemMessage":"frontmatter guard NOT CHECKED: ruby unavailable"}'
  exit 0
}

REPORT="$(ruby -ryaml -rdate -e '
  path = ARGV[0]
  src  = (File.read(path, encoding: "utf-8") rescue exit(0))
  exit(0) unless src.start_with?("---\n")
  e = src.index("\n---", 3) or begin
    puts "UNTERMINATED frontmatter fence"; exit(0)
  end
  block = src[4...e+1]
  begin
    YAML.safe_load(block, permitted_classes: [Date, Time], aliases: true)
  rescue Psych::SyntaxError => ex
    puts "INVALID YAML (Obsidian will discard the ENTIRE property block): #{ex.message}"
    exit(0)
  rescue StandardError
  end
  leaked = block.scan(/^\s*([A-Za-z_][A-Za-z0-9_-]*):\s*.*?(\{\{[A-Z_]+\}\})/).map { |k, p| "#{k}: #{p}" }
  puts "UNSUBSTITUTED TEMPLATE PLACEHOLDER in frontmatter -> #{leaked.uniq.join(", ")}" unless leaked.empty?
  bare = block.scan(/^([A-Za-z_][A-Za-z0-9_-]*):\s*\[\[[^\]]+\]\]\s*$/).flatten
  puts "DEGRADED bare wikilink (parses as a nested array, not a link) -> #{bare.uniq.join(", ")}" unless bare.empty?
' "$FILE" 2>/dev/null)"

[ -z "$REPORT" ] && exit 0

REL="${FILE#$VAULT/}"
printf '%s' "$REPORT" | REL="$REL" /usr/bin/python3 -c 'import json,sys,os
body = sys.stdin.read().strip()
print(json.dumps({"systemMessage": "Frontmatter guard on " + os.environ.get("REL","") + ":\n" + body + "\nFix before moving on. Verify the repair with Obsidian'"'"'s own parser, not PyYAML."}))' 2>/dev/null
exit 0
