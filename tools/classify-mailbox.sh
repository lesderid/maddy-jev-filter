#!/usr/bin/env bash
# Classifies the messages in a maddy mailbox, writing one result file per message.
#
#   classify-mailbox.sh [-n SAMPLE [-s SEED]] [-x EXCLUDE] [-j JOBS] [-c CONFIG] ACCOUNT MAILBOX OUTDIR
#
# Runs on the mail server as the maddy user, so it can use maddy's CLI:
#
#   sudo -u maddy tools/classify-mailbox.sh -n 300 user@example.org Junk /var/lib/maddy/jev-eval/v1/junk
#
# -n picks the same random sample every time, so configs can be compared on
# the same messages; -s picks a different one. -x leaves out the messages that
# have results in the directory EXCLUDE, for a sample that doesn't overlap one
# used for tuning. Messages that already have a successful result in OUTDIR
# are skipped: an interrupted or failed run can be resumed, and a changed
# config needs a new OUTDIR. The run stops early if Jev rejects the API key.
# Summarise the results with:
#
#   maddy-jev-filter.d --config=CONFIG report OUTDIR...
set -euo pipefail

sample='' seed=y exclude='' jobs=4 config=/etc/maddy/jev-filter.json
while getopts n:s:x:j:c: opt; do
    case $opt in
    n) sample=$OPTARG ;;
    s) seed=$OPTARG ;;
    x) exclude=$OPTARG ;;
    j) jobs=$OPTARG ;;
    c) config=$OPTARG ;;
    *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
if [[ $# != 3 ]]; then
    sed -n '3,/^set/{/^set/d;s/^# \{0,1\}//;p}' "$0" >&2
    exit 64
fi
account=$1 mailbox=$2 out=$3
filter=$(cd "$(dirname "$0")/.." && pwd)/maddy-jev-filter.d

mkdir -p "$out"
uids=$(maddy imap-msgs list "$account" "$mailbox" | { grep -aoP '^UID \K[0-9]+' || true; })
if [[ -n $exclude ]]; then
    uids=$(grep -vxFf <(find "$exclude" -name '*.json' -printf '%f\n' | sed 's/\.json$//') <<< "$uids" || true)
fi
if [[ -n $sample ]]; then
    uids=$(shuf -n "$sample" --random-source=<(yes "$seed") <<< "$uids")
fi

stop=$out/.unauthorized
rm -f "$stop"

classify_one() {
    local uid=$1 result=$out/$1.json
    [[ -e $stop ]] && return
    [[ -s $result ]] && ! grep -q '"error"' "$result" && return
    maddy imap-msgs dump --uid "$account" "$mailbox" "$uid" |
        "$filter" --config="$config" classify --tag="$mailbox/$uid" - > "$result.tmp" 2>/dev/null
    mv "$result.tmp" "$result"
    if grep -q '"error":"Jev returned HTTP 401' "$result"; then
        touch "$stop"
    fi
}
export -f classify_one
export account mailbox out filter config stop

xargs -P "$jobs" -n 1 bash -c 'classify_one "$0"' <<< "$uids"

if [[ -e $stop ]]; then
    rm -f "$stop"
    echo "stopped: Jev rejected the API key (HTTP 401)" >&2
    exit 1
fi
echo "$(find "$out" -name '*.json' | wc -l) results in $out," \
    "$(cat "$out"/*.json 2>/dev/null | grep -c '"error"') with errors" >&2
