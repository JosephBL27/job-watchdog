#!/bin/zsh
# launchd entry point for job-watchdog (com.joseph.job-watchdog, hourly + RunAtLoad).
#
# Runs through /bin/zsh and Apple's /usr/bin/ruby on purpose: /bin/zsh is the binary
# holding Full Disk Access here, and Homebrew interpreters HANG on ~/Documents under
# TCC instead of erroring (see ~/.config/carta/redraw.sh). No network unless
# ~/.config/job-watchdog/config.json opts in.
#
# The watcher must not become the next silent job: if the runner fails, say so out
# loud, and the SessionStart hook separately flags a status.json that is too old.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8"
BASE="$HOME/.config/job-watchdog"
LOG="$BASE/watchdog.log"
mkdir -p "$BASE/state"

# rotate at 512 KB
if [[ -f "$LOG" ]] && (( $(stat -f%z "$LOG" 2>/dev/null || echo 0) > 524288 )); then
  mv -f "$LOG" "$LOG.1"
fi

{
  echo "=== job-watchdog run $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  /usr/bin/ruby "$BASE/watchdog.rb" "$@"
} >> "$LOG" 2>&1
rc=$?

# Assert the ARTIFACT, not the exit code: status.json must have been rewritten now.
age=$(( $(date +%s) - $(stat -f %m "$BASE/status.json" 2>/dev/null || echo 0) ))
if (( rc != 0 )) || (( age > 120 )); then
  echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] RUNNER FAILED: rc=$rc status.json age=${age}s" >> "$LOG"
  /usr/bin/osascript -e 'display notification "job-watchdog runner failed; read ~/.config/job-watchdog/watchdog.log" with title "Job watchdog" sound name "Basso"' >/dev/null 2>&1
  exit 1
fi
exit 0
