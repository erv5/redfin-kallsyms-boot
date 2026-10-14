#!/usr/bin/env bash
# Low-cost watcher: tells you when it is actually worth standing up our own
# LineageOS 23 (redfin) build. It watches two independent signals and pings you
# (via a single tracking GitHub issue) only when one changes state:
#
#   1. Official redfin 23.x nightlies stop / move off 23  -> you lose prebuilt updates
#   2. The lineage-23.x source branch goes quiet          -> upstream stopped merging
#      (proxied by commit activity on LineageOS/android_frameworks_base lineage-23.x,
#       which receives the monthly security-bulletin merges)
#
# While both are healthy there is no reason to self-build: the official patched
# nightly already gives you everything a self-build would assemble.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY}"
DEVICE="${DEVICE:-redfin}"
TRACK_MAJOR="${TRACK_MAJOR:-23}"
STALE_BUILD_DAYS="${STALE_BUILD_DAYS:-21}"     # no new nightly in this long = official builds likely stopped
BRANCH_REPO="${BRANCH_REPO:-LineageOS/android_frameworks_base}"
BRANCH="${BRANCH:-lineage-23.x}"
BRANCH_STALE_DAYS="${BRANCH_STALE_DAYS:-45}"   # branch this quiet = upstream likely froze 23
LABEL="los23-watch"

now=$(date +%s)
days_since() { echo $(( (now - $1) / 86400 )); }

# --- Signal 1: official redfin build API ---------------------------------------
curl -fsSL "https://download.lineageos.org/api/v2/devices/${DEVICE}/builds" > builds.json
LATEST=$(jq -c 'sort_by(.datetime) | .[-1] // empty' builds.json)
if [ -z "$LATEST" ]; then
  BUILD_VER="(none)"; BUILD_DT=0; BUILD_AGE=9999; BUILD_DATE="never"
else
  BUILD_VER=$(echo "$LATEST" | jq -r '.version')
  BUILD_DT=$(echo "$LATEST" | jq -r '.datetime')
  BUILD_AGE=$(days_since "$BUILD_DT")
  BUILD_DATE=$(date -u -d "@$BUILD_DT" +%Y-%m-%d 2>/dev/null || date -u -r "$BUILD_DT" +%Y-%m-%d)
fi
BUILD_MAJOR="${BUILD_VER%%.*}"

# --- Signal 2: lineage-23.x branch liveness ------------------------------------
BR_DATE_ISO=$(gh api "repos/${BRANCH_REPO}/commits/${BRANCH}" --jq '.commit.committer.date' 2>/dev/null || true)
if [ -z "$BR_DATE_ISO" ]; then
  BRANCH_AGE=9999; BRANCH_DATE="gone/unknown"; BRANCH_GONE=1
else
  BR_DT=$(date -u -d "$BR_DATE_ISO" +%s 2>/dev/null || echo 0)
  BRANCH_AGE=$(days_since "$BR_DT")
  BRANCH_DATE=$(echo "$BR_DATE_ISO" | cut -dT -f1)
  BRANCH_GONE=0
fi

# --- Decide alerts -------------------------------------------------------------
ALERTS=()
[ "$BUILD_MAJOR" != "$TRACK_MAJOR" ] && [ "$BUILD_VER" != "(none)" ] && \
  ALERTS+=("VERSION_MOVED:newest redfin build is $BUILD_VER, no longer ${TRACK_MAJOR}.x")
[ "$BUILD_AGE" -gt "$STALE_BUILD_DAYS" ] && \
  ALERTS+=("BUILD_STALE:newest redfin build is ${BUILD_AGE}d old (> ${STALE_BUILD_DAYS}d) -> official nightlies may have stopped")
if [ "$BRANCH_GONE" = 1 ]; then
  ALERTS+=("BRANCH_GONE:${BRANCH} not found on ${BRANCH_REPO} -> branch likely retired")
elif [ "$BRANCH_AGE" -gt "$BRANCH_STALE_DAYS" ]; then
  ALERTS+=("BRANCH_FROZEN:${BRANCH} last commit ${BRANCH_AGE}d ago (> ${BRANCH_STALE_DAYS}d) -> upstream may have stopped patching 23")
fi

NEW_KEYS=$(printf '%s\n' "${ALERTS[@]:-}" | sed 's/:.*//' | grep -v '^$' | sort -u | paste -sd, - || true)
echo "readings: build=$BUILD_VER age=${BUILD_AGE}d  branch=$BRANCH_DATE age=${BRANCH_AGE}d  alerts=[${NEW_KEYS:-none}]"

# --- Maintain a single tracking issue -----------------------------------------
gh label create "$LABEL" -R "$REPO" --color ededed --description "LineageOS 23 self-build watch" 2>/dev/null || true
ISSUE=$(gh issue list -R "$REPO" --label "$LABEL" --state open --json number --jq '.[0].number' 2>/dev/null || true)

PREV_KEYS=""
if [ -n "$ISSUE" ]; then
  PREV_BODY=$(gh issue view "$ISSUE" -R "$REPO" --json body --jq '.body' 2>/dev/null || true)
  PREV_KEYS=$(printf '%s' "$PREV_BODY" | grep -oE '<!-- ALERTS: [^>]* -->' | sed -E 's/<!-- ALERTS: ?(.*) ?-->/\1/' | tr -d ' ' || true)
fi

STATUS="healthy (no action needed; keep taking official nightlies)"
[ -n "$NEW_KEYS" ] && STATUS="ACTION WORTH CONSIDERING -> time to look at self-building 23. See [[redfin-kernelsu-susfs-migration]] context and ping the assistant."

BODY=$(cat <<EOF
_Auto-updated by \`.github/workflows/los23-watch.yml\`. Last check: $(date -u +%Y-%m-%dT%H:%MZ)_

**Status: $STATUS**

| signal | reading | threshold | state |
|---|---|---|---|
| official $DEVICE build | \`$BUILD_VER\` dated $BUILD_DATE (${BUILD_AGE}d old) | <= ${STALE_BUILD_DAYS}d, major ${TRACK_MAJOR} | $( { [ "$BUILD_MAJOR" = "$TRACK_MAJOR" ] && [ "$BUILD_AGE" -le "$STALE_BUILD_DAYS" ]; } && echo OK || echo "ALERT") |
| \`$BRANCH\` activity | last commit $BRANCH_DATE (${BRANCH_AGE}d ago) | <= ${BRANCH_STALE_DAYS}d | $( [ "$BRANCH_GONE" = 0 ] && [ "$BRANCH_AGE" -le "$BRANCH_STALE_DAYS" ] && echo OK || echo "ALERT") |

What the alerts mean:
- **official build stale / moved**: you can no longer just take a patched 23 nightly for redfin. Self-building bridges this *as long as the branch is still alive*.
- **branch frozen / gone**: upstream stopped merging security patches into 23. Self-building now only reproduces a frozen snapshot; real patching would mean hand-backporting AOSP (heavy). Consider moving to the next LineageOS version instead.

<!-- ALERTS: ${NEW_KEYS} -->
EOF
)

if [ -z "$ISSUE" ]; then
  ISSUE=$(gh issue create -R "$REPO" --label "$LABEL" \
    --title "LineageOS 23 self-build watch (redfin)" --body "$BODY" \
    --json number --jq .number 2>/dev/null || gh issue list -R "$REPO" --label "$LABEL" --state open --json number --jq '.[0].number')
  echo "created tracking issue #$ISSUE"
else
  gh issue edit "$ISSUE" -R "$REPO" --body "$BODY" >/dev/null
  echo "updated tracking issue #$ISSUE"
fi

# Notify (comment) only on newly-tripped alerts, so you are not pinged weekly while stable.
for a in "${ALERTS[@]:-}"; do
  [ -z "$a" ] && continue
  key="${a%%:*}"; msg="${a#*:}"
  if ! printf ',%s,' "$PREV_KEYS" | grep -q ",$key,"; then
    gh issue comment "$ISSUE" -R "$REPO" --body ":rotating_light: **$key** tripped: $msg" >/dev/null || true
    echo "notified: $key"
  fi
done
echo "done."
