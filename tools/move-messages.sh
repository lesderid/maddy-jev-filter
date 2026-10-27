#!/usr/bin/env bash
# Moves the messages listed by `report --list` into another folder.
#
#   maddy-jev-filter.d report --list=INBOX RESULTS | move-messages.sh ACCOUNT FOLDER
#
# Runs as the maddy user, like classify-mailbox.sh. The first column of each
# line is a MAILBOX/UID tag as written by classify-mailbox.sh. FOLDER is
# created if it doesn't exist. IMAP clients that are connected may only notice
# the move after they resync.
set -euo pipefail

if [[ $# != 2 ]]; then
    sed -n '3,/^set/{/^set/d;s/^# \{0,1\}//;p}' "$0" >&2
    exit 64
fi
account=$1 target=$2

declare -A uids
while IFS=$'\t' read -r tag _; do
    uids[${tag%/*}]+=${uids[${tag%/*}]:+,}${tag##*/}
done

maddy imap-mboxes create "$account" "$target" 2>/dev/null || true
for mailbox in "${!uids[@]}"; do
    # In batches, to keep the command line short
    tr , '\n' <<< "${uids[$mailbox]}" | xargs -n 200 | tr ' ' , | while read -r batch; do
        maddy imap-msgs move --uid "$account" "$mailbox" "$batch" "$target"
    done
    echo "moved $(tr , '\n' <<< "${uids[$mailbox]}" | wc -l) messages from $mailbox to $target" >&2
done
