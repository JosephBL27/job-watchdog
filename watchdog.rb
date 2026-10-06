#!/usr/bin/ruby
# frozen_string_literal: true
#
# job-watchdog — asserts that scheduled jobs PRODUCED SOMETHING, not that they exited 0.
#
# WHY (2026-09-22): the one failure class that recurs on this machine is absence
# nobody observes. redeploy.sh stamped deploys that never installed; brain-steward
# exited 1 into a log for four weeks; advisor.sh printed "ADVISOR FAILED (exit 0)"
# for eleven weeks; the finder organizer has failed at 'codex classify' since July.
# Every one of those jobs "ran". None of them produced its artifact.
#
# So every check here names an ARTIFACT (a fresh file, a log line, a note field, a
# state field) and a max age that fits the job's schedule. Exit codes are never read
# as proof of success. The one exception (v4, 2026-09-24): run_outcome reads launchd's
# 'last exit code' as a FAILURE signal only, next to the log's own markers.
#
# Output:  ~/.config/job-watchdog/status.json   (read by the SessionStart hook)
# Alerts:  ONE channel abstraction. Default = macOS notification, at most one per
#          job per day. healthchecks.io and ntfy exist but are OFF unless
#          ~/.config/job-watchdog/config.json enables them. No config = zero network.
#
# Usage: watchdog.rb [--checks FILE] [--status FILE] [--state DIR] [--no-alert] [--quiet]
# Ruby 2.6 (system /usr/bin/ruby) compatible: stdlib only.

require 'json'
require 'time'
require 'date'
require 'net/http'
require 'uri'
require 'fileutils'
require 'open3'

# launchd provides no LANG, so Ruby defaults to US-ASCII and the first UTF-8 byte in
# a Codex automation.toml raises ArgumentError (found on the first launchd run).
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

HOME = ENV['HOME'] || Dir.home
BASE = File.join(HOME, '.config', 'job-watchdog')
VERSION = 4

opts = { checks: File.join(BASE, 'checks.json'), status: File.join(BASE, 'status.json'),
         state: File.join(BASE, 'state'), config: File.join(BASE, 'config.json'),
         alert: true, quiet: false }
args = ARGV.dup
until args.empty?
  a = args.shift
  case a
  when '--checks' then opts[:checks] = args.shift
  when '--status' then opts[:status] = args.shift
  when '--state'  then opts[:state]  = args.shift
  when '--config' then opts[:config] = args.shift
  when '--no-alert' then opts[:alert] = false
  when '--quiet' then opts[:quiet] = true
  else abort "unknown argument: #{a}"
  end
end

NOW = Time.now
STAMP_RE = /(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:\s?(?:[A-Z]{2,5}|[+-]\d{2}:?\d{2}|Z))?)/.freeze

def log(msg)
  warn "[job-watchdog #{NOW.strftime('%Y-%m-%d %H:%M:%S %Z')}] #{msg}"
end

$vars = {}
# An undefined (or empty) ${VAR} used to become '', so '${NOPE}/.pending_deploy'
# turned into '/.pending_deploy' and an 'absent' check passed against '/'. A path
# that cannot be resolved is now an error, never a guess (repair 2026-09-23 r2).
# strict: false is only for human-readable text (the 'fix' hint), which keeps the
# literal ${VAR} so the gap stays visible.
class UndefinedVariable < StandardError; end
def expand(path, strict: true)
  return nil if path.nil?
  p = path.gsub(/\$\{(\w+)\}/) do
    name = Regexp.last_match(1)
    val = $vars[name] || ENV[name]
    if val.nil? || val.to_s.empty?
      raise UndefinedVariable, "NOT CHECKED: undefined variable #{name} in '#{path}'" if strict
      "${#{name}}"
    else
      val
    end
  end
  p.start_with?('~') ? File.join(HOME, p[1..-1].sub(%r{\A/}, '')) : p
end

# iCloud/File Provider returns EDEADLK ("Resource deadlock avoided") on files that
# are mid-sync. Retry briefly; a read that still fails is reported as 'error'
# (NOT CHECKED), never silently as ok or as 0.
def with_retry(tries = 3)
  attempt = 0
  begin
    attempt += 1
    yield
  rescue Errno::EDEADLK, Errno::EAGAIN => e
    raise e if attempt >= tries
    sleep 0.4
    retry
  end
end

def hours_since(t)
  ((NOW - t) / 3600.0).round(2)
end

def human_age(h)
  return 'n/a' if h.nil?
  return "#{(h * 60).round}m" if h < 1
  return "#{h.round(1)}h" if h < 48
  "#{(h / 24).round(1)}d"
end

def parse_time(str)
  return nil if str.nil? || str.to_s.strip.empty?
  s = str.to_s.strip.delete('"').delete("'")
  if s =~ /\A\d{4}-\d{2}-\d{2}\z/
    return Time.local(*s.split('-').map(&:to_i))
  end
  Time.parse(s)
rescue ArgumentError
  nil
end

def newest_match(pattern, time_from)
  paths = Dir.glob(pattern)
  return [nil, nil] if paths.empty?
  best = nil
  best_t = nil
  paths.each do |p|
    t = nil
    if time_from == 'filename'
      m = File.basename(p).match(/(\d{4}-\d{2}-\d{2})(?:-(\d{2})(\d{2})(\d{2}))?/)
      if m
        y, mo, d = m[1].split('-').map(&:to_i)
        t = m[2] ? Time.local(y, mo, d, m[2].to_i, m[3].to_i, m[4].to_i) : Time.local(y, mo, d, 23, 59, 59)
        # A date-only filename is credited through the END of that day, then the
        # real mtime caps it so a note named for tomorrow cannot look fresher than now.
        t = [t, with_retry { File.mtime(p) }].min unless m[2]
      end
    end
    t ||= with_retry { File.mtime(p) }
    if best_t.nil? || t > best_t
      best_t = t
      best = p
    end
  end
  [best, best_t]
end

def read_tail(path, bytes)
  with_retry do
    File.open(path, 'rb') do |f|
      size = f.size
      f.seek([size - bytes, 0].max)
      f.read.to_s.force_encoding('UTF-8').scrub('?')
    end
  end
end

def frontmatter(path)
  text = with_retry { File.read(path, 65_536) }.to_s.force_encoding('UTF-8').scrub('?')
  return nil unless text.start_with?('---')
  body = text.split("\n")[1..-1] || []
  fm = {}
  body.each do |line|
    break if line.strip == '---'
    m = line.match(/\A([A-Za-z0-9_\-]+):\s*(.*)\z/)
    fm[m[1]] = m[2].strip if m
  end
  fm
end

# ---- check evaluators: each returns {status:, artifact_time:, evidence:, artifact:} ----

def eval_mtime(c)
  path = expand(c['path'])
  best, t = newest_match(path, c['time_from'])
  return { status: 'missing', evidence: "no file matches #{path}", artifact: path } if best.nil?
  { status: nil, artifact_time: t, artifact: best, evidence: "newest #{File.basename(best)} @ #{t.strftime('%Y-%m-%d %H:%M')}" }
end

def eval_frontmatter_time(c)
  path = expand(c['path'])
  return { status: 'missing', evidence: "note not found: #{path}", artifact: path } unless File.exist?(path)
  fm = frontmatter(path)
  return { status: 'error', evidence: 'no frontmatter fence', artifact: path } if fm.nil?
  raw = fm[c['key']]
  return { status: 'missing', evidence: "frontmatter has no '#{c['key']}'", artifact: path } if raw.nil? || raw.empty?
  t = parse_time(raw)
  return { status: 'error', evidence: "cannot parse #{c['key']}=#{raw}", artifact: path } if t.nil?
  # A date-only value (e.g. updated: 2026-09-20) is credited through end of day.
  t += 86_399 if raw.delete('"') =~ /\A\d{4}-\d{2}-\d{2}\z/
  t = NOW if t > NOW
  { status: nil, artifact_time: t, artifact: path, evidence: "#{c['key']}: #{raw.delete('"')}" }
end

# path may be a glob: the newest match (by mtime) is read. A numeric value is read
# as epoch seconds, or epoch milliseconds when it has 13 digits. error_key (optional)
# names a field that must be empty: a fresh record that carries an error is a run
# that fired and failed, reported as 'missing', never ok.
def json_dig(data, key)
  key.split('.').reduce(data) { |acc, k| acc.is_a?(Hash) ? acc[k] : nil }
end

def eval_json_time(c)
  pattern = expand(c['path'])
  path = if pattern =~ /[*?\[{]/
           best, _t = newest_match(pattern, nil)
           return { status: 'missing', evidence: "no file matches #{pattern}", artifact: pattern } if best.nil?
           best
         else
           pattern
         end
  return { status: 'missing', evidence: "state file not found: #{path}", artifact: path } unless File.exist?(path)
  data = JSON.parse(with_retry { File.read(path) })
  val = json_dig(data, c['key'])
  return { status: 'missing', evidence: "no '#{c['key']}' in #{File.basename(path)}", artifact: path } if val.nil?
  t = if val.is_a?(Numeric) || val.to_s =~ /\A\d{10,13}\z/
        n = val.to_s.to_i
        Time.at(n >= 10**12 ? n / 1000.0 : n)
      else
        parse_time(val)
      end
  return { status: 'error', evidence: "cannot parse #{c['key']}=#{val}", artifact: path } if t.nil?
  shown = t.strftime('%Y-%m-%d %H:%M')
  if c['error_key']
    err = json_dig(data, c['error_key'])
    unless err.nil? || err.to_s.strip.empty?
      return { status: 'missing', artifact_time: t, age_hours: hours_since(t), artifact: path,
               evidence: "#{File.basename(path)} @ #{shown} carries #{c['error_key']}: #{err.to_s[0, 140]}" }
    end
  end
  ev = val.is_a?(String) && val !~ /\A\d+\z/ ? "#{c['key']}=#{val}" : "#{File.basename(path)} #{c['key']} @ #{shown}"
  { status: nil, artifact_time: t, artifact: path, evidence: ev }
end

# Finds the LAST line matching `pattern`. Its time is a timestamp on that line, or
# failing that the nearest timestamped line ABOVE it (e.g. '=== advisor run <ts> ===').
# invert: true means the pattern must NOT have appeared within max_age_hours.
#
# An inverted check proves NOTHING when the log it reads is gone or has stopped being
# written: "no alarm line" and "nobody is writing alarms" look identical. So a missing
# log is 'error' (NOT CHECKED) unless the check sets allow_missing: true, and
# log_max_age_hours (optional) requires the log itself to be fresh first.
# (Repair 2026-09-23: a typo'd path used to report ok forever.)
def eval_log_marker(c)
  path = expand(c['path'])
  unless File.exist?(path)
    if c['invert']
      return { status: 'ok', evidence: 'log absent and allow_missing set', artifact: path } if c['allow_missing']
      return { status: 'error', evidence: "NOT CHECKED: log not found: #{path} (an absent log cannot prove an absent alarm)", artifact: path }
    end
    return { status: 'missing', evidence: "log not found: #{path}", artifact: path }
  end
  if c['log_max_age_hours']
    lt = with_retry { File.mtime(path) }
    la = hours_since(lt)
    if la > c['log_max_age_hours'].to_f
      return { status: 'stale', artifact_time: lt, age_hours: la, artifact: path,
               evidence: "log last written #{human_age(la)} ago (limit #{c['log_max_age_hours']}h), so its writer is not running; alarm state NOT CHECKED" }
    end
  end
  text = read_tail(path, (c['tail_bytes'] || 4_000_000).to_i)
  lines = text.split("\n")
  # Positive heartbeat for inverted checks (repair 2026-09-23 r2). A fresh log only
  # proves the WRITER runs, not that the check inside it ran: backup-user-data.sh
  # can log "N check(s) could NOT be verified - this is not a pass" hourly, or lose
  # check_delivery entirely, and "no alarm line" would still read as ok. So the log
  # must also carry a REAL verdict line (heartbeat_pattern) within
  # heartbeat_max_age_hours, or the alarm state is NOT CHECKED and the job is stale.
  if c['invert'] && c['heartbeat_pattern']
    hb = find_marker(lines, Regexp.new(c['heartbeat_pattern']))
    hb_max = (c['heartbeat_max_age_hours'] || c['log_max_age_hours'] || c['max_age_hours']).to_f
    nc = c['not_checked_pattern'] ? find_marker(lines, Regexp.new(c['not_checked_pattern'])) : nil
    nc_note = nc && nc[:time] && (hb.nil? || hb[:time].nil? || nc[:time] >= hb[:time]) ? "; newest run said: '#{nc[:line]}' @ #{nc[:time].strftime('%Y-%m-%d %H:%M')}" : ''
    if hb.nil? || hb[:time].nil?
      return { status: 'stale', artifact: path,
               evidence: "NOT CHECKED: no verdict line '#{c['heartbeat_pattern']}' anywhere in the log tail, so no run in it recorded a result#{nc_note}" }
    end
    hb_age = hours_since(hb[:time])
    if hb_age > hb_max
      return { status: 'stale', artifact_time: hb[:time], age_hours: hb_age, artifact: path,
               evidence: "NOT CHECKED: last real verdict '#{hb[:line]}' was #{human_age(hb_age)} ago (limit #{hb_max}h), so recent runs skipped the check#{nc_note}" }
    end
  end
  re = Regexp.new(c['pattern'])
  m = find_marker(lines, re)
  if m.nil?
    return { status: 'ok', evidence: "no '#{c['pattern']}' in log", artifact: path } if c['invert']
    return { status: 'missing', evidence: "'#{c['pattern']}' never appears in #{File.basename(path)}", artifact: path }
  end
  t = m[:time]
  snippet = m[:line]
  return { status: 'error', evidence: "matched '#{snippet}' but found no timestamp near it", artifact: path } if t.nil?
  if c['invert']
    age = hours_since(t)
    max = c['max_age_hours'].to_f
    st = age <= max ? 'stale' : 'ok'
    # age_hours too, so status.json, the banner and the notification show an age
    # (r1 skeptic: it printed 'n/a' for this check).
    return { status: st, artifact_time: t, artifact: path, age_hours: age, alarm_age_hours: age, invert: true,
             evidence: "#{st == 'stale' ? 'ALARM LINE' : 'last alarm line'} @ #{t.strftime('%Y-%m-%d %H:%M')}: #{snippet}" }
  end
  { status: nil, artifact_time: t, artifact: path, evidence: "last '#{snippet}' @ #{t.strftime('%Y-%m-%d %H:%M')}" }
end

# The LAST line matching re, and its time: a timestamp on that line or failing that
# the nearest timestamped line ABOVE it. nil when nothing matches.
def find_marker(lines, re)
  idx = lines.rindex { |l| l =~ re }
  return nil if idx.nil?
  t = nil
  idx.downto([idx - 400, 0].max) do |i|
    m = lines[i].match(STAMP_RE)
    next unless m
    t = parse_time(m[1])
    break if t
  end
  { line: lines[idx].strip[0, 160], time: t }
end

# A marker's absence only means something if the place it would appear exists.
# If the parent directory is gone (repo moved or renamed, typo'd var), the check
# is NOT CHECKED, never ok. Optional must_exist: a sibling path that must also
# exist (e.g. the script that writes the marker) for the absence to count.
def eval_absent(c)
  path = expand(c['path'])
  dir = File.dirname(path)
  unless File.directory?(dir)
    return { status: 'error', artifact: path, evidence: "NOT CHECKED: parent directory missing: #{dir} (an absent marker in a missing place proves nothing)" }
  end
  Array(c['must_exist']).each do |m|
    mp = expand(m)
    next if File.exist?(mp)
    return { status: 'error', artifact: path, evidence: "NOT CHECKED: #{mp} missing, so nothing would write #{File.basename(path)}" }
  end
  if File.exist?(path)
    t = File.mtime(path)
    return { status: 'stale', artifact_time: t, artifact: path, age_hours: hours_since(t),
             evidence: "#{File.basename(path)} PRESENT since #{t.strftime('%Y-%m-%d %H:%M')}" }
  end
  { status: 'ok', artifact: path, evidence: "#{File.basename(path)} absent" }
end

# The vault autocommit is silent when the tree is clean, so its artifact is the
# ABSENCE of old uncommitted work: the oldest dirty file must be younger than max.
def eval_git_clean_age(c)
  repo = expand(c['path'])
  env = { 'GIT_OPTIONAL_LOCKS' => '0' }
  out, err, st = Open3.capture3(env, 'git', '-c', 'core.fsmonitor=false', '-C', repo, 'status', '--porcelain', '-z')
  return { status: 'error', evidence: "git status failed: #{err.strip[0, 120]}", artifact: repo } unless st.success?
  entries = out.split("\0").reject(&:empty?)
  return { status: 'ok', artifact: repo, evidence: 'working tree clean' } if entries.empty?
  oldest = nil
  oldest_path = nil
  entries.each do |e|
    rel = e[3..-1]
    next if rel.nil? || rel.empty?
    full = File.join(repo, rel)
    t = File.exist?(full) ? (File.lstat(full).mtime rescue NOW) : NOW
    if oldest.nil? || t < oldest
      oldest = t
      oldest_path = rel
    end
  end
  oldest ||= NOW
  { status: nil, artifact_time: oldest, artifact: repo,
    evidence: "#{entries.size} uncommitted path(s); oldest #{oldest_path} @ #{oldest.strftime('%Y-%m-%d %H:%M')}" }
end

def eval_http_local(c)
  uri = URI.parse(c['url'])
  unless %w[127.0.0.1 localhost ::1].include?(uri.host)
    return { status: 'error', evidence: "http_local refuses non-loopback host #{uri.host}", artifact: c['url'] }
  end
  code = begin
    Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 3) { |h| h.request(Net::HTTP::Get.new(uri.request_uri)).code.to_i }
  rescue StandardError => e
    e.class.name.split('::').last
  end
  expect = (c['expect_status'] || 200).to_i
  if code == expect
    return { status: 'ok', artifact: c['url'], evidence: "#{c['url']} answered #{code}" }
  end
  ctx = ''
  cl = expand(c['context_log'])
  if cl && File.exist?(cl)
    last = read_tail(cl, 4096).split("\n").last.to_s.strip
    ctx = "; keeper last: #{last[0, 140]}" unless last.empty?
  end
  { status: 'missing', artifact: c['url'], evidence: "#{c['url']} -> #{code} (expected #{expect})#{ctx}" }
end

# Repair 2026-09-24 r3b: this used to read a literal 'created' date from checks.json
# and report 'ok'. The steward token died with 401 on 09-20 while this said ok, and
# the replacement file (born 09-22) still read "created 2026-07-03". Two fixes:
#  1. The created date is the FILE'S BIRTH TIME (`stat -f %B`, the same field as
#     `stat -f %SB`), so replacing the token restarts the clock by itself. If the
#     birth time cannot be read the check is NOT CHECKED, never a guess.
#  2. The best this check can say is that the documented lifetime has not run out.
#     It never calls the API (no credential is ever tested against a live service),
#     so it cannot know the token works. Its best status is therefore
#     'lifetime-ok (not validated)', never 'ok'. Only a job's own artifact (the
#     steward pass, the advisor's APPENDED OK) proves a token authenticates.
# A checks.json 'created' literal that disagrees with the birth date is reported.
TOKEN_UNVALIDATED = 'lifetime-ok (not validated)'
def eval_token_expiry(c)
  path = expand(c['path'])
  return { status: 'missing', artifact: path, evidence: "token file missing: #{path}" } unless File.exist?(path)
  mode = format('%o', File.stat(path).mode & 0o777)
  out, _err, st = Open3.capture3('/usr/bin/stat', '-f', '%B', path)
  born = st.success? && out.strip =~ /\A\d+\z/ && out.strip.to_i.positive? ? Time.at(out.strip.to_i) : nil
  return { status: 'error', artifact: path, evidence: "NOT CHECKED: could not read the birth time of #{path} (stat -f %B failed)" } if born.nil?
  created = born.to_date
  mtime = File.mtime(path)
  expires = created + c['lifetime_days'].to_i
  days_left = (expires - Date.today).to_i
  ev = "created #{born.strftime('%Y-%m-%d %H:%M')} (file birth time)"
  ev += ", rewritten in place #{mtime.strftime('%Y-%m-%d %H:%M')} (birth time kept, so the lifetime is counted from the older date)" if mtime - born > 60
  ev += ", documented lifetime #{c['lifetime_days']}d, expires ~#{expires} (#{days_left}d left), mode #{mode}"
  ev += "; checks.json 'created' literal #{c['created']} DISAGREES and is ignored" if c['created'] && c['created'].to_s != created.to_s
  ev += '; NOT VALIDATED: no API call is made, so this proves only the lifetime, not that the token authenticates'
  return { status: 'missing', artifact: path, artifact_time: born, evidence: "EXPIRED: #{ev}" } if days_left <= 0
  return { status: 'stale', artifact: path, artifact_time: born, evidence: "EXPIRING SOON: #{ev}" } if days_left <= c['warn_days'].to_i
  return { status: 'stale', artifact: path, artifact_time: born, evidence: "INSECURE MODE: #{ev}" } unless mode == '600'
  { status: TOKEN_UNVALIDATED, artifact: path, artifact_time: born, evidence: ev }
end

# run_outcome (repair 2026-09-24 r3b): did the job's LAST RUN finish?
# Written for internship-digest, which is installed in dry-run mode on purpose: it
# prints a digest and writes nothing, so the artifact is the completion line itself.
# It used to be reported 'paused/info' and hid a real failure (09-23: exit 1,
# "Error: GEMINI_API_KEY not found ..." with no start line, because the key lookup
# failed before the script logged anything).
#
# Failure signals (any one fails the run):
#   a. an error_pattern line AFTER the last success line (a later run died);
#   b. a start_pattern line after the last success line and the job not running now;
#   c. launchd 'last exit code' nonzero. The exit code is used ONLY as a FAILURE
#      signal, never as proof of success (a script ending in echo exits 0).
# Success needs a success_pattern line with a timestamp younger than max_age_hours.
# An unreadable log or launchctl output is NOT CHECKED, never ok.
def launchd_job_state(label)
  out, _e, st = Open3.capture3('/bin/launchctl', 'print', "gui/#{UID}/#{label}")
  return nil unless st.success?
  top = out.split("\n").select { |l| l =~ /\A\t[a-z]/ } # top-level keys only (one tab)
  state = top.map { |l| l[/\A\tstate = (.+)\z/, 1] }.compact.first
  exit_line = top.map { |l| l[/\A\tlast exit code = (.+)\z/, 1] }.compact.first
  { state: state, last_exit: exit_line }
end

def eval_run_outcome(c)
  path = expand(c['path'])
  return { status: 'error', artifact: path, evidence: "NOT CHECKED: log not found: #{path}" } unless File.exist?(path)
  logs = [path] + Array(c['extra_logs']).map { |p| expand(p) }.select { |p| File.exist?(p) }
  last_write = logs.map { |p| with_retry { File.mtime(p) } }.max
  lines = read_tail(path, (c['tail_bytes'] || 2_000_000).to_i).split("\n")
  succ_re = Regexp.new(c['success_pattern'])
  si = lines.rindex { |l| l =~ succ_re }
  after = si ? lines[(si + 1)..-1] : lines
  errs = c['error_pattern'] ? after.select { |l| l =~ Regexp.new(c['error_pattern']) } : []
  starts = c['start_pattern'] ? after.select { |l| l =~ Regexp.new(c['start_pattern']) } : []
  ld = nil
  if c['launchd_label']
    ld = launchd_job_state(c['launchd_label'])
    return { status: 'error', artifact: path, evidence: "NOT CHECKED: launchctl print #{c['launchd_label']} failed" } if ld.nil?
  end
  running = ld && ld[:state] == 'running'
  exit_s = ld ? ld[:last_exit].to_s : ''
  exit_bad = exit_s =~ /\A-?\d+\z/ && exit_s.to_i != 0
  fails = []
  fails << "#{errs.size} error line(s) after the last success, newest: '#{errs.last.strip[0, 140]}'" if errs.any? && !running
  fails << "a run started after the last success and never logged completion ('#{starts.last.strip[0, 80]}')" if starts.any? && !running
  fails << "launchd last exit code = #{exit_s}" if exit_bad && !running
  succ = si ? find_marker(lines[0..si], succ_re) : nil
  succ_s = succ && succ[:time] ? "last success '#{succ[:line]}' @ #{succ[:time].strftime('%Y-%m-%d %H:%M')}" : 'no success line in the log tail'
  mode_s = c['mode'] ? " (#{c['mode']} mode is intended; the contract is only that each run completes)" : ''
  if fails.any?
    return { status: 'missing', artifact: path, artifact_time: last_write, age_hours: succ && succ[:time] ? hours_since(succ[:time]) : nil,
             failed_run: true,
             evidence: "LAST RUN FAILED (log last written #{last_write.strftime('%Y-%m-%d %H:%M')}): #{fails.join('; ')}; #{succ_s}#{mode_s}" }
  end
  return { status: 'missing', artifact: path, evidence: "#{succ_s}; no failure signal either, so the job has not completed a run in this log#{mode_s}" } if succ.nil?
  return { status: 'error', artifact: path, evidence: "NOT CHECKED: success line '#{succ[:line]}' has no timestamp" } if succ[:time].nil?
  run_s = running ? '; a run is in progress now' : ''
  { status: nil, artifact: path, artifact_time: succ[:time],
    evidence: "#{succ_s}; no error or unfinished run after it; launchd last exit #{exit_s.empty? ? 'n/a' : exit_s}#{run_s}#{mode_s}" }
end

EVALUATORS = {
  'mtime' => method(:eval_mtime), 'frontmatter_time' => method(:eval_frontmatter_time),
  'json_time' => method(:eval_json_time), 'log_marker' => method(:eval_log_marker),
  'absent' => method(:eval_absent), 'git_clean_age' => method(:eval_git_clean_age),
  'http_local' => method(:eval_http_local), 'token_expiry' => method(:eval_token_expiry),
  'run_outcome' => method(:eval_run_outcome)
}.freeze

def evaluate_leaf(c, max_age)
  fn = EVALUATORS[c['type']]
  return { status: 'error', evidence: "unknown check type '#{c['type']}'" } if fn.nil?
  r = fn.call(c)
  if r[:status].nil? # a time-bearing artifact; judge age here
    age = hours_since(r[:artifact_time])
    r[:age_hours] = age
    r[:status] = age <= max_age ? 'ok' : 'stale'
  end
  r
rescue UndefinedVariable => e
  { status: 'error', evidence: e.message[0, 200] }
rescue StandardError => e
  { status: 'error', evidence: "NOT CHECKED: #{e.class}: #{e.message[0, 160]}" }
end

def evaluate(c)
  max_age = (c['max_age_hours'] || 0).to_f
  return evaluate_leaf(c, max_age) unless c['type'] == 'any_of'
  # An empty any_of used to crash the whole runner (subs.first was nil).
  return { status: 'error', evidence: 'NOT CHECKED: any_of has no sub-checks' } if Array(c['checks']).empty?
  subs = (c['checks'] || []).map { |s| evaluate_leaf(s, (s['max_age_hours'] || max_age).to_f) }
  ok = subs.select { |s| s[:status] == 'ok' }
  pick = if ok.any?
           ok.min_by { |s| s[:age_hours] || 0 }
         else
           timed = subs.select { |s| s[:age_hours] }
           timed.any? ? timed.min_by { |s| s[:age_hours] } : subs.first
         end
  rank = { 'ok' => 0, 'stale' => 1, 'missing' => 2, 'error' => 3 }
  status = ok.any? ? 'ok' : (subs.map { |s| s[:status] }.min_by { |s| rank[s] || 9 } || 'missing')
  pick.merge(status: status, evidence: subs.map { |s| "[#{s[:status]}] #{s[:evidence]}" }.join(' | '))
end

UID = Process.uid
def launchd_loaded?(label)
  _o, _e, st = Open3.capture3('/bin/launchctl', 'print', "gui/#{UID}/#{label}")
  st.success?
end

# Claude Desktop scheduled tasks, READ ONLY. Each profile keeps its own
# scheduled-tasks.json; this reads them and never writes inside a profile dir.
CLAUDE_TASK_GLOB = File.join(HOME, 'Library', 'Application Support', 'Claude*',
                             '{local-agent-mode-sessions,claude-code-sessions}', '*', '*', 'scheduled-tasks.json')
$claude_task_errors = []
def claude_tasks
  @claude_tasks ||= begin
    out = {}
    Dir.glob(CLAUDE_TASK_GLOB).sort.each do |f|
      data = begin
        JSON.parse(with_retry { File.read(f) })
      rescue StandardError => e
        $claude_task_errors << "#{f.sub(HOME, '~')}: #{e.class}"
        next
      end
      profile = f.split('/Application Support/', 2).last.to_s.split('/').first
      (data['scheduledTasks'] || []).each do |t|
        next unless t['id']
        prev = out[t['id']]
        rec = { id: t['id'], enabled: t['enabled'] == true, cron: t['cronExpression'] || t['fireAt'],
                last_run_at: t['lastRunAt'], profile: profile, path: f }
        # The same task can be mirrored in two session dirs; enabled anywhere wins.
        out[t['id']] = prev && prev[:enabled] && !rec[:enabled] ? prev : rec
      end
    end
    out
  end
end

def codex_status(id)
  f = File.join(HOME, '.codex', 'automations', id, 'automation.toml')
  return nil unless File.exist?(f)
  File.foreach(f) { |l| return Regexp.last_match(1) if l =~ /\Astatus\s*=\s*"([A-Z_]+)"/ }
  nil
end

# ---- WHY a Codex job is stale (repair 2026-09-23 r2) -------------------------
# A stale artifact says THAT a job stopped; it does not say WHY. Round one found
# Canvas intake runs dying ~3 s after start on "You've hit your usage limit", which
# looks identical to "the Codex app is not running" from the artifact side. Codex
# records each automation run in ~/.codex/sqlite/codex-dev.db (automation_runs:
# thread_id -> automation_id) and each run's outcome in its rollout,
# ~/.codex/sessions/YYYY/MM/DD/rollout-*-<thread_id>.jsonl, whose task_complete
# event carries error.codex_error_info == "usage_limit_exceeded". Both are READ ONLY
# here (sqlite3 -readonly, mode=ro). If either cannot be read, the cause is
# reported as NOT CHECKED, never omitted.
CODEX_DB = File.join(HOME, '.codex', 'sqlite', 'codex-dev.db')
CODEX_RECENT = 10
$codex_runs = nil
$codex_runs_error = nil
def codex_runs
  return $codex_runs if $codex_runs || $codex_runs_error
  unless File.exist?(CODEX_DB)
    $codex_runs_error = "NOT CHECKED: #{CODEX_DB.sub(HOME, '~')} not found"
    return nil
  end
  sql = 'select automation_id, thread_id, created_at from (select automation_id, thread_id, created_at, ' \
        'row_number() over (partition by automation_id order by created_at desc) rn from automation_runs) ' \
        "where rn <= #{CODEX_RECENT} order by automation_id, created_at desc"
  out, err, st = Open3.capture3('/usr/bin/sqlite3', '-readonly', '-json', "file:#{CODEX_DB}?mode=ro", sql)
  unless st.success?
    $codex_runs_error = "NOT CHECKED: sqlite3 could not read codex-dev.db: #{err.strip[0, 120]}"
    return nil
  end
  rows = out.strip.empty? ? [] : JSON.parse(out)
  $codex_runs = rows.group_by { |r| r['automation_id'] }
rescue StandardError => e
  $codex_runs_error = "NOT CHECKED: #{e.class}: #{e.message[0, 120]}"
  nil
end

def codex_rollout(thread_id, created_ms)
  t = Time.at(created_ms / 1000.0)
  dirs = [-1, 0, 1].map { |d| (t + d * 86_400).strftime('%Y/%m/%d') }.uniq
  dirs.each do |d|
    hit = Dir.glob(File.join(HOME, '.codex', 'sessions', d, "rollout-*#{thread_id}.jsonl")).first
    return hit if hit
  end
  Dir.glob(File.join(HOME, '.codex', 'archived_sessions', "rollout-*#{thread_id}.jsonl")).first
end

# Outcome of one run: usage_limit | error | completed | running | unknown.
def codex_run_outcome(row)
  f = codex_rollout(row['thread_id'], row['created_at'].to_i)
  return { outcome: 'unknown', note: 'rollout file not found' } if f.nil?
  last = nil
  read_tail(f, 1_048_576).each_line do |l|
    next unless l.include?('"task_complete"')
    ev = JSON.parse(l) rescue next
    last = ev['payload'] if ev.dig('payload', 'type') == 'task_complete'
  end
  return { outcome: 'running', note: 'no task_complete event (still running or cut off)' } if last.nil?
  err = last['error']
  dur = last['duration_ms']
  return { outcome: 'completed', duration_ms: dur } if err.nil?
  info = err.is_a?(Hash) ? err['codex_error_info'].to_s : ''
  msg = err.is_a?(Hash) ? err['message'].to_s : err.to_s
  retry_at = msg[/try again at ([^.]{1,40})/i, 1]
  if info == 'usage_limit_exceeded' || msg =~ /hit your usage limit/i
    return { outcome: 'usage_limit', duration_ms: dur, retry_at: retry_at }
  end
  # Only the error CLASS is recorded, not the free-text message.
  { outcome: 'error', duration_ms: dur, error_info: info.empty? ? 'unclassified' : info }
rescue StandardError => e
  { outcome: 'unknown', note: "NOT CHECKED: #{e.class}: #{e.message[0, 100]}" }
end

$codex_last_run = {}
def codex_last_run(automation_id)
  return $codex_last_run[automation_id] if $codex_last_run.key?(automation_id)
  runs = codex_runs
  res = if runs.nil?
          { error: $codex_runs_error }
        elsif (rows = runs[automation_id]).nil? || rows.empty?
          { error: 'no run of this automation is recorded in codex-dev.db' }
        else
          outs = rows.map { |r| codex_run_outcome(r).merge(at: Time.at(r['created_at'].to_i / 1000.0)) }
          latest = outs.first
          { at: latest[:at].iso8601, at_time: latest[:at], outcome: latest[:outcome],
            duration_ms: latest[:duration_ms], retry_at: latest[:retry_at], error_info: latest[:error_info],
            note: latest[:note], thread_id: rows.first['thread_id'],
            recent_usage_limit: outs.count { |o| o[:outcome] == 'usage_limit' }, recent_runs: outs.size,
            # Every examined run, newest first, so codex_cause can judge the runs SINCE
            # the artifact rather than only the latest one (r2 repair). history_complete:
            # fewer rows than the window means this is every run codex-dev.db has.
            runs: outs.map { |o| { at: o[:at].iso8601, outcome: o[:outcome] } },
            history_complete: rows.size < CODEX_RECENT }.compact
        end
  $codex_last_run[automation_id] = res
end

# A one-line cause for a stale/missing Codex job, or nil when nothing is known.
#
# The cause is judged over EVERY examined run since the last artifact, not only the
# latest (r2 repair, skeptic finding): canvas-intake was stale 20.7d, its four runs
# 09-18..09-21 COMPLETED without producing the artifact, and only the 09-22 run hit
# the usage limit. Blaming the limit there sent Joseph to buy credits for a failure
# the limit did not cause. The prefix "killed by Codex usage limit" (which the
# notification and the session banner key their tag on) is used ONLY when every
# examined run since the artifact hit the limit. When the window of runs does not
# reach back to the artifact, the text says so rather than implying it does.
def codex_cause(job, lr)
  return "cause #{lr[:error]}" if lr[:error] && lr[:error].start_with?('NOT CHECKED')
  return lr[:error] if lr[:error]
  at = lr[:at_time].strftime('%Y-%m-%d %H:%M')
  secs = lr[:duration_ms] ? " after #{(lr[:duration_ms] / 1000.0).round(1)}s" : ''
  tally = "#{lr[:recent_usage_limit]} of last #{lr[:recent_runs]} runs hit the limit"
  art = job[:artifact_time] ? (Time.parse(job[:artifact_time].to_s) rescue nil) : nil
  runs = (lr[:runs] || []).map { |r| r.merge(t: (Time.parse(r[:at]) rescue nil)) }
  since = art ? runs.select { |r| r[:t] && r[:t] > art } : runs
  # Does the examined window reach back to (or past) the artifact? If not, runs
  # between the artifact and the oldest examined run were NOT examined.
  oldest = runs.map { |r| r[:t] }.compact.min
  covered = lr[:history_complete] || (art && oldest && oldest <= art)
  art_s = art ? art.strftime('%Y-%m-%d %H:%M') : 'no artifact'
  gap = covered ? '' : "; runs before #{oldest ? oldest.strftime('%Y-%m-%d %H:%M') : '?'} NOT CHECKED"
  case lr[:outcome]
  when 'usage_limit'
    retry_hint = lr[:retry_at] ? "; Codex said try again at #{lr[:retry_at]}" : ''
    if art && lr[:at_time] < art
      "latest Codex run #{at} hit the usage limit, but it predates the last artifact, so the job has not run since (#{tally})"
    elsif since.all? { |r| r[:outcome] == 'usage_limit' }
      n = since.size
      scope = art ? "#{n == 1 ? 'the only examined run' : "all #{n} examined runs"} since the last artifact (#{art_s})" : (n == 1 ? 'the only examined run' : "all #{n} examined runs")
      "killed by Codex usage limit: #{scope} hit the limit#{gap}; latest #{at} died#{secs}#{retry_hint}"
    else
      breakdown = since.group_by { |r| r[:outcome] }.map { |k, v| "#{v.size} #{k}" }.join(', ')
      done = since.count { |r| r[:outcome] == 'completed' }
      lead = if done.positive?
               "#{done} Codex run(s) since the last artifact (#{art_s}) completed without producing it"
             else
               "Codex runs since the last artifact (#{art_s}) did not produce it"
             end
      "#{lead}; the latest, #{at}, hit the usage limit#{retry_hint}, but the limit is not the whole cause (runs since the artifact: #{breakdown})#{gap}"
    end
  when 'error' then "latest Codex run #{at} ended with error #{lr[:error_info]}#{secs}"
  when 'completed'
    if art.nil? || lr[:at_time] > art
      "latest Codex run #{at} completed#{secs} but did not produce the artifact"
    else
      "no Codex run since #{at} (that run completed); check the Codex app is running"
    end
  when 'running' then "latest Codex run #{at} has no completion record (still running or cut off)"
  else "latest Codex run #{at}: cause NOT CHECKED (#{lr[:note]})"
  end
end

# ---------------------------------------------------------------------------
cfg_checks = JSON.parse(File.read(opts[:checks]))
$vars = cfg_checks['vars'] || {}
config = File.exist?(opts[:config]) ? (JSON.parse(File.read(opts[:config])) rescue {}) : {}

jobs = []
(cfg_checks['checks'] || []).each do |c|
  job = { id: c['id'], name: c['name'], schedule: c['schedule'], severity: c['severity'] || 'warn',
          type: c['type'], max_age_hours: c['max_age_hours'], fix: c['fix'] ? expand(c['fix'], strict: false) : nil }
  begin
  paused_reason = nil
  mode = c['mode'] || 'active'
  paused_reason = c['reason'] || mode if %w[paused dryrun retired].include?(mode)
  # A dry-run job that is still LOADED and RUNNING is not paused: dry-run is its
  # intended mode, and its contract is that each run completes. alert_on_failure
  # keeps it out of 'paused' so a failed run alerts (repair 2026-09-24 r3b: the
  # 09-23 internship-digest failure hid as 'paused/info').
  if mode == 'dryrun' && c['alert_on_failure']
    paused_reason = nil
    job[:mode] = 'dryrun (intended)'
  end
  if c['paused_if_exists'] && File.exist?(expand(c['paused_if_exists']))
    paused_reason ||= "pause switch present: #{c['paused_if_exists']}"
  end
  if c['codex_automation']
    cs = codex_status(c['codex_automation'])
    job[:codex_status] = cs || 'NOT FOUND'
    if cs.nil?
      paused_reason ||= nil
      job[:drift] = "codex automation #{c['codex_automation']} not found" unless paused_reason
    elsif cs != 'ACTIVE'
      paused_reason ||= "Codex automation status #{cs}"
    elsif paused_reason
      job[:drift] = "marked #{mode} here but Codex says ACTIVE; give it a real check"
    end
  end
  if c['claude_task']
    ct = claude_tasks[c['claude_task']]
    job[:claude_task_enabled] = ct ? ct[:enabled] : 'NOT FOUND'
    if ct.nil?
      job[:drift] = "Claude Desktop task #{c['claude_task']} not found" unless paused_reason
    elsif !ct[:enabled]
      paused_reason ||= "Claude Desktop task disabled (#{ct[:profile]})"
    elsif paused_reason
      job[:drift] = "marked #{mode} here but Claude Desktop says enabled; give it a real check"
    end
  end
  job[:sidecar] = c['sidecar'] if c['sidecar']
  if c['launchd_label']
    job[:launchd_label] = c['launchd_label']
    job[:launchd_loaded] = launchd_loaded?(c['launchd_label'])
  end

  r = c['type'] == 'none' ? { status: nil, evidence: 'no artifact contract' } : evaluate(c)
  job[:evidence] = r[:evidence]
  job[:failed_run] = true if r[:failed_run]
  job[:artifact] = r[:artifact]
  job[:age_hours] = r[:age_hours]
  job[:age] = human_age(r[:age_hours])
  job[:artifact_time] = r[:artifact_time]&.iso8601
  if paused_reason
    job[:status] = 'paused'
    job[:paused_reason] = paused_reason
    job[:artifact_status] = r[:status]
    # A job we believe is paused but whose artifact is FRESH is running anyway
    # (e.g. a paused sidecar coming back after an app restart).
    # A fresh event that carries an error still proves the scheduler FIRED, so
    # freshness is judged by age, not by status == ok (r1 skeptic finding).
    fired_recently = r[:status] == 'ok' || (r[:age_hours] && r[:age_hours] <= (c['max_age_hours'] || 0).to_f)
    if c['drift_if_fresh'] && fired_recently
      # Key fact first: readers truncate (the banner keeps ~110 chars).
      job[:drift] = "RUNNING while marked paused: #{r[:evidence].to_s[0, 120]} (paused because: #{paused_reason.to_s[0, 120]})"
    end
  else
    job[:status] = r[:status] || 'error'
    if job[:launchd_label] && !job[:launchd_loaded]
      # A job that is not loaded will never run again: absence by construction.
      job[:status] = 'missing' if job[:status] == 'ok' || job[:status] == 'stale'
      job[:evidence] = "LaunchAgent #{job[:launchd_label]} NOT LOADED; #{job[:evidence]}"
    end
    if c['codex_automation'] && %w[stale missing].include?(job[:status])
      lr = codex_last_run(c['codex_automation'])
      job[:codex_last_run] = lr.reject { |k, _| k == :at_time }
      job[:cause] = codex_cause(job, lr)
    end
  end
  rescue StandardError => e
    # One bad check entry must not stop every other check (r1: an empty any_of
    # crashed the runner). It is reported, loudly, as its own error.
    job[:status] = 'error'
    job[:evidence] = e.is_a?(UndefinedVariable) ? e.message[0, 200] : "NOT CHECKED: #{e.class}: #{e.message[0, 160]}"
  end
  jobs << job
end

# Discovery: scheduled things nobody declared. New jobs must not be born unwatched.
#
# Coverage is only as good as the list of SURFACES scanned, so status.json records
# every surface, how many schedules it held, and whether the scan itself worked. A
# surface that cannot be read becomes an unwatched 'surface-error' entry, so an empty
# 'unwatched' list never silently means "we did not look". Surfaces known to exist
# but NOT scannable are listed under discovery.not_covered (from checks.json).
# (Repair 2026-09-23: v1 scanned only two LaunchAgent prefixes and Codex, and missed
# two live Antigravity sidecars.)
all_checks = cfg_checks['checks'] || []
covered_labels = jobs.map { |j| j[:launchd_label] }.compact
covered_codex = all_checks.map { |c| c['codex_automation'] }.compact
covered_sidecars = all_checks.map { |c| c['sidecar'] }.compact
covered_ctasks = all_checks.map { |c| c['claude_task'] }.compact
untracked = cfg_checks['untracked'] || {}
ul = untracked['launchd'] || {}
uprefix = untracked['launchd_prefixes'] || {}
uc = untracked['codex'] || {}
us = untracked['sidecar'] || {}
ut = untracked['claude_task'] || {}
ucron = untracked['cron'] || {}
unwatched = []
surfaces = []

def scan_surface(surfaces, unwatched, name, where)
  rec = { name: name, where: where, scanned: 0, scheduled: 0, unwatched: 0, error: nil }
  before = unwatched.size
  begin
    yield rec
  rescue StandardError => e
    rec[:error] = "#{e.class}: #{e.message[0, 140]}"
    unwatched << { kind: 'surface-error', id: name, note: "could not scan #{where}: #{rec[:error]}" }
  end
  rec[:unwatched] = unwatched.size - before
  surfaces << rec
end

LAUNCHD_DIRS = [File.join(HOME, 'Library', 'LaunchAgents'), '/Library/LaunchAgents', '/Library/LaunchDaemons'].freeze
# 'scheduled' counts only plists that can start on their own: StartInterval,
# StartCalendarInterval, RunAtLoad or KeepAlive (r1 skeptic: it counted every file).
# A plist plutil cannot parse is counted under 'unparsed' and still needs a check or
# a reason, so an unreadable file cannot hide a schedule.
LAUNCHD_SCHEDULE_KEYS = %w[StartInterval StartCalendarInterval RunAtLoad KeepAlive].freeze
def launchd_schedule_keys(p)
  out, _e, st = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-', p)
  return nil unless st.success?
  d = JSON.parse(out)
  LAUNCHD_SCHEDULE_KEYS.select do |k|
    v = d[k]
    !(v.nil? || v == false || (v.respond_to?(:empty?) && v.empty?))
  end
rescue StandardError
  nil
end
scan_surface(surfaces, unwatched, 'launchd', LAUNCHD_DIRS.map { |d| "#{d}/*.plist" }.join(', ')) do |rec|
  rec[:unparsed] = 0
  LAUNCHD_DIRS.each do |d|
    next unless File.directory?(d)
    Dir.glob(File.join(d, '*.plist')).sort.each do |p|
      rec[:scanned] += 1
      label = File.basename(p, '.plist')
      keys = launchd_schedule_keys(p)
      if keys.nil?
        rec[:unparsed] += 1
      elsif keys.any?
        rec[:scheduled] += 1
      end
      next if covered_labels.include?(label) || ul.key?(label)
      next if uprefix.keys.any? { |pre| label.start_with?(pre) }
      unwatched << { kind: 'launchd', id: label, path: p, schedule_keys: keys || 'UNPARSED' }
    end
  end
end

scan_surface(surfaces, unwatched, 'codex', File.join(HOME, '.codex', 'automations', '*', 'automation.toml')) do |rec|
  Dir.glob(File.join(HOME, '.codex', 'automations', '*', 'automation.toml')).sort.each do |f|
    rec[:scanned] += 1
    id = File.basename(File.dirname(f))
    st = codex_status(id)
    rec[:scheduled] += 1 if st == 'ACTIVE'
    next if covered_codex.include?(id)
    next if uc.key?(id) && st != 'ACTIVE'
    next unless st == 'ACTIVE' || !uc.key?(id)
    unwatched << { kind: 'codex', id: id, codex_status: st, path: f }
  end
end

SIDECAR_GLOB = File.join(HOME, '.gemini', 'config', 'sidecars', '*', 'sidecar.json')
scan_surface(surfaces, unwatched, 'antigravity-sidecar', SIDECAR_GLOB) do |rec|
  Dir.glob(SIDECAR_GLOB).sort.each do |f|
    rec[:scanned] += 1
    data = begin
      JSON.parse(with_retry { File.read(f) })
    rescue StandardError => e
      # One unreadable file must not hide the others: report it and keep scanning.
      rec[:error] = 'unreadable sidecar.json'
      unwatched << { kind: 'surface-error', id: "antigravity-sidecar:#{File.basename(File.dirname(f))}",
                     note: "cannot read #{f.sub(HOME, '~')}: #{e.class}; its schedule is unknown" }
      next
    end
    next unless data['builtin'] == 'schedule'
    rec[:scheduled] += 1
    id = File.basename(File.dirname(f))
    next if covered_sidecars.include?(id) || us.key?(id)
    unwatched << { kind: 'sidecar', id: id, cron: Array(data['args']).first, display: data['displayName'], path: f }
  end
end

scan_surface(surfaces, unwatched, 'claude-desktop-task', CLAUDE_TASK_GLOB) do |rec|
  rec[:files] = Dir.glob(CLAUDE_TASK_GLOB).size
  claude_tasks.each_value do |t|
    rec[:scanned] += 1
    next unless t[:enabled]
    rec[:scheduled] += 1
    next if covered_ctasks.include?(t[:id]) || ut.key?(t[:id])
    unwatched << { kind: 'claude_task', id: t[:id], cron: t[:cron], profile: t[:profile], path: t[:path] }
  end
  $claude_task_errors.each { |e| unwatched << { kind: 'surface-error', id: 'claude-desktop-task', note: "unreadable: #{e}" } }
  rec[:error] = "#{$claude_task_errors.size} unreadable file(s)" if $claude_task_errors.any?
end

scan_surface(surfaces, unwatched, 'crontab', 'crontab -l') do |rec|
  out, err, st = Open3.capture3('/usr/bin/crontab', '-l')
  unless st.success?
    raise "crontab -l: #{err.strip}" unless err =~ /no crontab/i
    out = ''
  end
  out.each_line do |l|
    line = l.strip
    next if line.empty? || line.start_with?('#') || line =~ /\A\w+=/
    rec[:scanned] += 1
    rec[:scheduled] += 1
    next if ucron.key?(line)
    unwatched << { kind: 'cron', id: line[0, 80], line: line }
  end
end

# Drift entries go FIRST in unwatched, so a reader that truncates the list (the
# SessionStart banner names only the first few) cannot fold them away.
unwatched.unshift(*jobs.select { |j| j[:drift] }.map { |j| { kind: 'drift', id: j[:id], note: j[:drift] } })
discovery = { surfaces: surfaces, not_covered: cfg_checks['discovery_not_covered'] || {} }

# Drift ALERTS (repair 2026-09-23 r2). A paused job that is running again used to
# appear only in 'unwatched', so severity: high on a paused sidecar did
# nothing. Now any drift alerts, paused or not, at the job's severity; 'info' is
# promoted to 'warn' because a job running when it should not is never just info.
# Order: drift first, then high severity, then the rest.
SEV_RANK = { 'high' => 0, 'warn' => 1, 'info' => 2 }.freeze
alerting = jobs.select { |j| j[:drift] || (%w[stale missing error].include?(j[:status]) && j[:severity] != 'info') }
alerting.each { |j| j[:alert_severity] = j[:drift] && j[:severity] == 'info' ? 'warn' : j[:severity] }
alerting = alerting.each_with_index.sort_by { |j, i| [j[:drift] ? 0 : 1, SEV_RANK[j[:alert_severity]] || 1, i] }.map(&:first)
def alert_status(j)
  j[:drift] ? 'drift' : j[:status]
end
summary = Hash.new(0)
jobs.each { |j| summary[j[:status]] += 1 }

# ---- alert channel (ONE abstraction; notification default, network opt-in) ----
FileUtils.mkdir_p(opts[:state])
sent_path = File.join(opts[:state], 'alerts-sent.json')
sent = File.exist?(sent_path) ? (JSON.parse(File.read(sent_path)) rescue {}) : {}
today = NOW.strftime('%Y-%m-%d')
jobs.each { |j| sent.delete(j[:id]) if j[:status] == 'ok' || j[:status] == TOKEN_UNVALIDATED || (j[:status] == 'paused' && !j[:drift]) } # recovered: re-arm
# Dedupe is per job, per day, per KIND of alert (r2 repair, skeptic finding): a
# 'NOT CHECKED' alert used to spend the job's one notification for the day, so a
# real ALARM later the same day stayed silent until tomorrow. The key is
# "YYYY-MM-DD:<kind>". A bare "YYYY-MM-DD" (written before this change) still
# dedupes every kind except not_checked, so this upgrade does not re-send today's alerts.
def alert_kind(j)
  return 'drift' if j[:drift]
  j[:evidence].to_s.start_with?('NOT CHECKED') ? 'not_checked' : j[:status].to_s
end
def already_sent?(sent, j, today)
  v = sent[j[:id]]
  v == "#{today}:#{alert_kind(j)}" || (v == today && alert_kind(j) != 'not_checked')
end
fresh = alerting.reject { |j| already_sent?(sent, j, today) }

channels = config['channels'] || {}
notify_on = channels.fetch('macos_notification', true)
delivered = []
delivered_ok = false

def osa_escape(s)
  s.to_s.gsub('\\', '\\\\\\').gsub('"', '\\"')
end

if opts[:alert] && fresh.any?
  body = fresh.map do |j|
    s = "#{j[:id]} #{alert_status(j)}#{j[:age_hours] && !j[:drift] ? " (#{j[:age]})" : ''}"
    s += ' [Codex usage limit]' if j[:cause].to_s.start_with?('killed by Codex usage limit')
    s
  end.join(', ')
  ndrift = fresh.count { |j| j[:drift] }
  title = "Job watchdog: #{fresh.size} job#{fresh.size == 1 ? '' : 's'} silent"
  title = "Job watchdog: #{ndrift} paused job#{ndrift == 1 ? '' : 's'} RUNNING, #{fresh.size - ndrift} silent" if ndrift.positive?
  if notify_on
    _o, _e, st = Open3.capture3('/usr/bin/osascript', '-e',
                                "display notification \"#{osa_escape(body[0, 230])}\" with title \"#{osa_escape(title)}\" sound name \"Basso\"")
    delivered << "macos_notification:#{st.success? ? 'ok' : 'failed'}"
  end
  ntfy = channels['ntfy']
  if ntfy.is_a?(Hash) && ntfy['enabled'] && ntfy['topic_url'].to_s.start_with?('https://')
    begin
      u = URI.parse(ntfy['topic_url'])
      req = Net::HTTP::Post.new(u.request_uri)
      req['Title'] = title
      req['Priority'] = fresh.any? { |j| j[:alert_severity] == 'high' } ? 'high' : 'default'
      req.body = body
      res = Net::HTTP.start(u.host, u.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req) }
      delivered << "ntfy:#{res.code}"
    rescue StandardError => e
      delivered << "ntfy:#{e.class.name.split('::').last}"
    end
  end
  # Mark a job as alerted ONLY when some channel actually delivered it; a failed
  # osascript (or every channel off) must retry next hour, not go quiet till tomorrow.
  delivered_ok = delivered.any? { |d| d =~ /:(ok|2\d\d)\z/ }
  fresh.each { |j| sent[j[:id]] = "#{today}:#{alert_kind(j)}" } if delivered_ok
end

# healthchecks.io: ping a job's URL ONLY when its artifact check passed. A missed
# ping is how healthchecks detects absence; pinging unconditionally would recreate
# the exit-0 lie this tool exists to kill.
hc = channels['healthchecks']
hc_results = {}
if opts[:alert] && hc.is_a?(Hash) && hc['enabled']
  (hc['ping_urls'] || {}).each do |id, url|
    j = jobs.find { |x| x[:id] == id }
    next unless j && j[:status] == 'ok' && url.to_s.start_with?('https://')
    begin
      u = URI.parse(url)
      code = Net::HTTP.start(u.host, u.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(Net::HTTP::Get.new(u.request_uri)).code }
      hc_results[id] = code
    rescue StandardError => e
      hc_results[id] = e.class.name.split('::').last
    end
  end
end

File.write(sent_path, JSON.pretty_generate(sent))

status = {
  generator: "job-watchdog v#{VERSION}",
  generated_at: NOW.iso8601,
  checks_file: opts[:checks],
  summary: summary,
  alerting: alerting.map { |j| { id: j[:id], status: alert_status(j), severity: j[:alert_severity], age: j[:drift] ? nil : j[:age], drift: j[:drift], cause: j[:cause], evidence: j[:evidence] }.compact },
  codex_cause_lookup: $codex_runs_error || ($codex_runs ? 'ok' : 'not needed'),
  unwatched: unwatched,
  discovery: discovery,
  # Only jobs some channel actually delivered; 'pending' = due but not delivered.
  notified_this_run: opts[:alert] && delivered_ok ? fresh.map { |j| j[:id] } : [],
  alert_pending: opts[:alert] && !delivered_ok ? fresh.map { |j| j[:id] } : [],
  delivered: delivered,
  healthchecks: hc_results,
  jobs: jobs
}
tmp = "#{opts[:status]}.tmp.#{Process.pid}"
File.write(tmp, JSON.pretty_generate(status) + "\n")
File.rename(tmp, opts[:status]) # atomic: the hook never reads a half-written file

unless opts[:quiet]
  jobs.each do |j|
    puts format('%-8s %-26s %-6s %s', j[:status], j[:id], j[:age], j[:evidence].to_s[0, 150])
    puts "         DRIFT: #{j[:drift]}" if j[:drift]
    puts "         cause: #{j[:cause]}" if j[:cause]
  end
  puts "unwatched: #{unwatched.map { |u| "#{u[:kind]}:#{u[:id]}" }.join(', ')}" if unwatched.any?
  puts 'surfaces: ' + surfaces.map { |s| "#{s[:name]}=#{s[:error] ? 'ERROR' : "#{s[:scheduled]}/#{s[:scanned]}"}" }.join(' ')
  puts "alerting=#{alerting.size} notified=#{status[:notified_this_run].size} #{delivered.join(' ')}"
end
exit 0
