#!/usr/bin/env bash
# Turns the messages in a folder into examples for a question, such as the
# mail in "Not interested" for the not_interested question.
#
#   update-examples.sh [-c CONFIG] [-n MESSAGES] [-s SUBJECTS] ACCOUNT FOLDER OUTFILE
#
# Runs as the maddy user, like classify-mailbox.sh. Writes a JSON list with
# one entry per sender address in FOLDER: the sender and recipient of their
# newest message, and the subjects of up to SUBJECTS (default 25) of their
# newest messages, without repeats. Reads the newest MESSAGES (default 5000).
# A question can then include, for each message, only the entries from its
# sender with {"include_for_sender": "OUTFILE"} (see README.md). A message
# moved out of FOLDER stops being an example the next time this runs.
set -euo pipefail

config=/etc/maddy/jev-filter.json max=5000 subjects=25
while getopts c:n:s: opt; do
    case $opt in
    c) config=$OPTARG ;;
    n) max=$OPTARG ;;
    s) subjects=$OPTARG ;;
    *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
if [[ $# != 3 ]]; then
    sed -n '3,/^set/{/^set/d;s/^# \{0,1\}//;p}' "$0" >&2
    exit 64
fi
account=$1 folder=$2 out=$3
filter=$(cd "$(dirname "$0")/.." && pwd)/maddy-jev-filter.d

uids=$(maddy imap-msgs list "$account" "$folder" | { grep -aoP '^UID \K[0-9]+' || true; } | sort -n | tail -n "$max")

# One cached example per UID, so a run only reads messages it hasn't seen
cache=$out.d
mkdir -p "$cache"
for uid in $uids; do
    [[ -s $cache/$uid.json ]] && continue
    maddy imap-msgs dump --uid "$account" "$folder" "$uid" |
        "$filter" --config="$config" state - | jq -c '{from, to, subject}' > "$cache/$uid.json.tmp"
    mv "$cache/$uid.json.tmp" "$cache/$uid.json"
done
for file in "$cache"/*.json; do
    [[ -e $file ]] || continue
    grep -qxF "$(basename "$file" .json)" <<< "$uids" || rm "$file"
done

# Newest first, grouped by sender address, in the order senders were last seen
for uid in $(sort -rn <<< "$uids"); do cat "$cache/$uid.json"; done | jq -s --argjson max "$subjects" '
    def address: ([scan("[^<>\\s\"]+@[^<>\\s\"]+")] | last) // . | ascii_downcase;
    reduce .[] as $m ({order: [], senders: {}};
        ($m.from // "" | address) as $key
        | if .senders[$key] == null
            then .order += [$key] | .senders[$key] = {from: $m.from, to: $m.to, subjects: []}
            else . end
        | if $m.subject != null and (.senders[$key].subjects | index([$m.subject])) == null
                and (.senders[$key].subjects | length) < $max
            then .senders[$key].subjects += [$m.subject]
            else . end)
    | [.order[] as $key | .senders[$key] | with_entries(select(.value != null and .value != []))]' > "$out.tmp"
mv "$out.tmp" "$out"
echo "$(jq length "$out") senders, $(jq '[.[].subjects | length] | add // 0' "$out") subjects in $out" >&2
