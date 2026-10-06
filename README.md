# job-watchdog

Every hour, a Ruby script checks each scheduled job on my Mac by looking for the
thing that job was supposed to make: a dated note in my Obsidian vault, a
commit, a log line, a fresh timestamp. Exit codes are never taken as proof,
because a job can exit 0 and produce nothing.

## How it works

- **Declare.** Each job gets a check in `checks.json` that names an artifact and
  how old it may get. [checks.example.json](checks.example.json) is a subset of
  mine: the vault autocommit, the weekly brain-steward pass, the daily Brain
  Health note, the Sunday chart redraw, the file organizer, the Obsidian API
  endpoint, inbox intake and course intake.
- **Sweep.** [watchdog.rb](watchdog.rb) runs hourly under launchd, on the system
  Ruby with the standard library only. Check types include fresh file (`mtime`),
  log line (`log_marker`), note frontmatter field (`frontmatter_time`), JSON
  state field (`json_time`), clean git tree (`git_clean_age`), local HTTP
  endpoint (`http_local`), a file that must not exist (`absent`), token age
  (`token_expiry`) and combinations (`any_of`).
- **Classify.** Each job comes out ok, stale, missing, paused, or NOT CHECKED
  when the artifact cannot be read. It is never ok by default. A paused job
  whose artifact turns fresh again is flagged as drift and goes to the top.
- **Discover.** It also lists every scheduled job it can find on the machine
  (launchd agents, scheduled agent automations) that has no check, so a new job
  cannot slip in unwatched.
- **Alert.** One macOS notification per job per day, and one line at the top of
  each new agent session through [hooks/session-start-setup.sh](hooks/session-start-setup.sh).
- **Watch the watcher.** [run.sh](run.sh) checks that `status.json` was
  rewritten within 120 seconds of the run; if not, it sends its own alert.

[hooks/vault-frontmatter-guard.sh](hooks/vault-frontmatter-guard.sh) is the
companion check on the vault side: after every agent write to a vault note, it
parses the note's frontmatter with a real YAML parser and reports a note that
would break.

## Run it

```bash
mkdir -p ~/.config/job-watchdog
cp watchdog.rb run.sh ~/.config/job-watchdog/
cp checks.example.json ~/.config/job-watchdog/checks.json   # then edit the paths and jobs
/usr/bin/ruby ~/.config/job-watchdog/watchdog.rb --no-alert  # writes ~/.config/job-watchdog/status.json
```

Options: `--checks FILE`, `--status FILE`, `--state DIR`, `--config FILE`,
`--no-alert`, `--quiet`. No network is used unless a `config.json` turns on an
outside alert channel.

Joseph Blumberg · josephblumberg325@gmail.com
