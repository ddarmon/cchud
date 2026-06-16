#!/usr/bin/env bash
# Claude Code status line.
# Receives a JSON blob on stdin and prints two formatted lines. Line 1 is
# fixed-position metrics; line 2 holds the variable-length location (dir +
# branch + PR), so a long path or branch never crowds out the usage %:
#   Opus 4.8  │  ctx 97%  │  $0.83 ($16/h)  │  +120 -34  │  5h 12% = 2h13m  ·  wk 3% =
#   ~/dir  ⎇ branch  ·  PR #123
#
# The usage segment (5h session / 7d weekly + pace) comes straight from the
# .rate_limits field of the stdin payload — no API call, token, or cache.

input=$(cat)

dir=$(echo "$input"   | jq -r '.cwd')
cwd="$dir"   # raw path, kept for git/gh which need a real directory
model=$(echo "$input" | jq -r '.model.display_name')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
# NB: don't use `// empty` on booleans — jq's // fires on false too.
thinking=$(echo "$input" | jq -r '.thinking.enabled')   # true | false | null
effort=$(echo "$input" | jq -r '.effort.level // empty')
fast=$(echo "$input" | jq -r '.fast_mode')               # true | false | null
added=$(echo "$input"  | jq -r '.cost.total_lines_added // empty')
removed=$(echo "$input"| jq -r '.cost.total_lines_removed // empty')
dur_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // empty')   # wall-clock (grows during idle)
api_ms=$(echo "$input" | jq -r '.cost.total_api_duration_ms // empty') # active-inference time (idle-immune)
session_id=$(echo "$input" | jq -r '.session_id // empty')           # stable per-session state key

# --- palette (ANSI-C quoting -> real escape chars) --------------------------
R=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'
CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; MAGENTA=$'\033[35m'
SEP="  ${DIM}│${R}  "
BR=$'\xe2\x8e\x87'   # ⎇ git-branch glyph

color_pct() {  # usage %: low=good=green, high=bad=red
  awk -v p="$1" 'BEGIN{ if (p<50) printf "\033[32m"; else if (p<80) printf "\033[33m"; else printf "\033[31m" }'
}

# --- working directory (collapse $HOME -> ~) --------------------------------
case "$dir" in
  "$HOME") dir="~" ;;
  "$HOME"/*) dir="~${dir#"$HOME"}" ;;
esac
dirseg="${BOLD}${CYAN}${dir}${R}"

# --- model + thinking level -------------------------------------------------
# thinking.enabled toggles extended thinking; effort.level is its depth.
modeseg=""
if [ "$thinking" = "true" ]; then
  modeseg=" ${DIM}·${R} ${MAGENTA}think ${effort:-on}${R}"
elif [ "$thinking" = "false" ]; then
  modeseg=" ${DIM}· think off${R}"
fi
[ "$fast" = "true" ] && modeseg="${modeseg} ${DIM}·${R} ${YELLOW}fast${R}"
modelseg="${DIM}${model}${R}${modeseg}"

now=$(date +%s)   # single clock read, shared by cost burn rate and usage pace

# --- context window (% used) ------------------------------------------------
ctxseg=""
[ -n "$used" ] && ctxseg="${SEP}${DIM}ctx${R} $(color_pct "$used")$(printf '%.0f' "$used")%${R}"

# --- session cost (+ recent burn rate $/h, idle-aware) ----------------------
# The rate is a *sliding window* of recent spend, not a session-lifetime
# average. Assumptions (the first two confirmed empirically from live payloads):
#   1. .cost.total_duration_ms tracks WALL-CLOCK and keeps growing while idle,
#      so cost/total_duration dilutes toward $0 after any break -> unusable as
#      a "current burn" rate. (Do not "simplify" the rate back to it.)
#   2. .cost.total_api_duration_ms advances ONLY during active inference, so it
#      is idle-immune -> safe as the cold-start fallback rate (cost/api_time).
#   3. .cost.total_cost_usd is cumulative & monotonically increasing within a
#      session; a DECREASE means the session was reset (e.g. compaction /
#      --continue), handled below by restarting the snapshot history.
#   4. .session_id is a stable per-session key, so distinct sessions get
#      distinct cache files and never cross-contaminate each other's rate.
# The statusline only runs when a render fires, but the window/idle logic is
# correct whether or not renders fire during idle: snapshots older than the
# window are pruned, and last-change time is tracked separately (file line 1)
# so idle is still detectable after the window has fully rolled over.
#
# We persist (ts, cost) snapshots per session_id and report Δcost/Δt over the
# last CACHE_WINDOW seconds. When cost has been flat for IDLE_AFTER seconds we
# show "idle" instead of a misleading near-$0 rate.
CACHE_WINDOW=300   # 5-min look-back for the recent burn rate
IDLE_AFTER=120     # cost flat this many secs -> show "idle"
costseg=""
if [ -n "$cost" ]; then
  costseg="${SEP}${YELLOW}\$$(printf '%.2f' "$cost")${R}"

  idle=0; rateval=""
  if [ -n "$session_id" ]; then
    cdir="$HOME/.claude/.cost-cache"; mkdir -p "$cdir" 2>/dev/null
    cf="$cdir/$session_id.tsv"
    find "$cdir" -type f -mtime +1 -delete 2>/dev/null   # GC abandoned sessions

    # File format: line 1 = "<last-change-ts>\t<cost-at-change>" (survives
    # window pruning, so idle can be detected past the window); lines 2+ =
    # windowed "<ts>\t<cost>" snapshots. awk rewrites the file atomically and
    # emits "<idle>\t<rate>" (rate empty when there isn't enough span yet).
    res=$({ [ -f "$cf" ] && cat "$cf"; } | awk \
      -v now="$now" -v cost="$cost" -v win="$CACHE_WINDOW" -v idleA="$IDLE_AFTER" \
      -v api="${api_ms:-0}" -v tmpf="$cf.$$.tmp" '
      BEGIN { n=0 }   # ensure snapshot array is 0-indexed even with no history
      NR==1 { lc_ts=$1; lc_cost=$2; have=1; next }
            { ts[n]=$1; cs[n]=$2; n++ }
      END {
        if      (!have)                 { lc_ts=now; lc_cost=cost }
        else if (cost+0 < lc_cost+0)    { lc_ts=now; lc_cost=cost; n=0 }  # cost reset
        else if (cost+0 > lc_cost+0)    { lc_ts=now; lc_cost=cost }       # cost rose
        ts[n]=now; cs[n]=cost; n++                                        # current snapshot

        print lc_ts "\t" lc_cost > tmpf
        found=0
        for (i=0; i<n; i++) if (ts[i]+0 >= now-win) {
          print ts[i] "\t" cs[i] > tmpf
          if (!found || ts[i]+0 < o_ts) { o_ts=ts[i]; o_cost=cs[i]; found=1 }
        }
        close(tmpf)

        idle = (now - lc_ts > idleA) ? 1 : 0
        span = now - o_ts
        if      (span >= 60 && cost+0 > o_cost+0) rate = (cost-o_cost)*3600/span
        else if (api+0 > 60000)                   rate = cost*3600000/(api+0)  # idle-immune fallback
        else                                      rate = -1                   # too little data yet
        if (rate < 0) printf "%d\t", idle; else printf "%d\t%.6f", idle, rate
      }')
    [ -f "$cf.$$.tmp" ] && mv -f "$cf.$$.tmp" "$cf" 2>/dev/null
    idle=${res%%$'\t'*}; rateval=${res#*$'\t'}
  elif [ -n "$dur_ms" ] && [ "$dur_ms" -gt 60000 ] 2>/dev/null; then
    rateval=$(awk -v c="$cost" -v d="$dur_ms" 'BEGIN{ print c*3600000/d }')  # no session_id: lifetime avg
  fi

  if [ "$idle" = "1" ]; then
    costseg="${costseg} ${DIM}(idle)${R}"
  elif [ -n "$rateval" ]; then
    rate=$(awk -v r="$rateval" 'BEGIN{ if (r>=10) printf "%.0f", r; else printf "%.1f", r }')
    costseg="${costseg} ${DIM}(\$${rate}/h)${R}"
  fi
fi

# --- lines added / removed this session -------------------------------------
linesseg=""
la=${added:-0}; lr=${removed:-0}
if [ "$la" -gt 0 ] 2>/dev/null || [ "$lr" -gt 0 ] 2>/dev/null; then
  linesseg="${SEP}${GREEN}+${la}${R} ${RED}-${lr}${R}"
fi

fmt_dur() {  # secs -> compact countdown: 3d4h | 2h13m | 45m
  local s=$1; (( s < 0 )) && s=0
  local d=$(( s/86400 )) h=$(( (s%86400)/3600 )) m=$(( (s%3600)/60 ))
  if   (( d > 0 )); then printf '%dd%dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh%dm' "$h" "$m"
  else                   printf '%dm' "$m"
  fi
}

# --- usage limits (straight from .rate_limits — no network) -----------------
# resets_at is epoch seconds; pace = how far through the rolling window we are.
pace_pct() {  # args: reset_epoch window_secs -> elapsed % (empty if unknown)
  local reset_ts=$1
  { [ -z "$reset_ts" ] || [ "$reset_ts" = "null" ]; } && { echo ""; return; }
  local remaining=$(( reset_ts - now )); (( remaining < 0 )) && remaining=0
  local elapsed=$(( $2 - remaining ))
  awk -v e="$elapsed" -v w="$2" 'BEGIN{ printf "%.1f", e*100/w }'
}
pace_glyph() {  # args: util pace -> colored arrow ( > +5 ahead, < -5 behind )
  [ -z "$2" ] && return
  awk -v u="$1" -v p="$2" 'BEGIN{
    d=u-p;
    if (d>5)        printf " \033[31m\xe2\x86\x91\033[0m";   # up   = ahead of pace
    else if (d<-5)  printf " \033[32m\xe2\x86\x93\033[0m";   # down = behind pace
    else            printf " \033[2m=\033[0m";               # on pace
  }'
}

five=$(echo "$input"       | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week=$(echo "$input"       | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

usageseg=""; parts=""
if [ -n "$five" ]; then
  g=$(pace_glyph "$five" "$(pace_pct "$five_reset" 18000)")
  r=""   # countdown to when the 5h window rolls over
  { [ -n "$five_reset" ] && [ "$five_reset" != "null" ]; } && r=" ${DIM}$(fmt_dur $(( five_reset - now )))${R}"
  parts="${DIM}5h${R} $(color_pct "$five")$(printf '%.0f' "$five")%${R}${g}${r}"
fi
if [ -n "$week" ]; then
  [ -n "$parts" ] && parts="$parts  ${DIM}·${R}  "
  g=$(pace_glyph "$week" "$(pace_pct "$week_reset" 604800)")
  parts="${parts}${DIM}wk${R} $(color_pct "$week")$(printf '%.0f' "$week")%${R}${g}"
fi
[ -n "$parts" ] && usageseg="${SEP}${parts}"

# --- git branch + PR (PR cached, background-refreshed) ----------------------
# A custom statusLine fully replaces Claude Code's default line, so the git
# branch / PR it used to show have to be rebuilt here from $cwd. This lives on
# its own second line, so no leading separator here.
gitseg=""
branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -n "$branch" ]; then
  gitseg="${DIM}${BR}${R} ${GREEN}${branch}${R}"   # ⎇ branch

  groot=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  key=$(printf '%s' "$groot:$branch" | md5 -q 2>/dev/null || printf '%s' "$groot:$branch" | md5sum 2>/dev/null | cut -d' ' -f1)
  prdir="$HOME/.claude/.pr-cache"; pf="$prdir/$key.json"
  pmtime=0; [ -f "$pf" ] && pmtime=$(stat -f %m "$pf" 2>/dev/null || echo 0)

  if [ -n "$key" ] && [ $((now - pmtime)) -ge 120 ]; then
    {
      mkdir -p "$prdir"
      if cd "$cwd" 2>/dev/null && gh pr view --json number,state,isDraft > "$pf.tmp" 2>/dev/null; then
        mv "$pf.tmp" "$pf"
      else
        rm -f "$pf.tmp"; printf '{}' > "$pf"   # no PR / gh unavailable: cache the negative
      fi
    } &
    disown 2>/dev/null
  fi

  if [ -f "$pf" ]; then
    num=$(jq -r '.number // empty' "$pf" 2>/dev/null)
    state=$(jq -r '.state // empty' "$pf" 2>/dev/null)
    draft=$(jq -r '.isDraft // false' "$pf" 2>/dev/null)
    if [ -n "$num" ]; then
      pc="$GREEN"                                   # OPEN
      [ "$state" = "MERGED" ] && pc="$MAGENTA"
      [ "$state" = "CLOSED" ] && pc="$RED"
      [ "$draft" = "true" ]   && pc="$DIM"          # draft: muted
      gitseg="${gitseg} ${DIM}·${R} ${pc}PR #${num}${R}"
    fi
  fi
fi

# Line 1: fixed-position metrics (modelseg has no leading separator).
# Line 2: location — dir, plus branch + PR when in a git repo.
line1="${modelseg}${ctxseg}${costseg}${linesseg}${usageseg}"
locseg="${dirseg}"
[ -n "$gitseg" ] && locseg="${locseg}  ${gitseg}"
printf '%s\n%s' "$line1" "$locseg"
