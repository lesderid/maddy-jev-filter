#!/usr/bin/env bash
# Lists everyone an account has kept mail from, and everyone it has written to.
#
#   update-kept-senders.sh [-d DATABASE] [-j JUNKFILE] ACCOUNT OUTFILE
#
# Reads maddy's imapsql database (read-only, as the maddy user) and writes one
# address per line: the senders of all messages outside Junk, Not interested,
# Suspicious, Trash, Drafts and Sent, and the recipients of everything in
# Sent. The filter's kept_senders_file setting points at OUTFILE (see
# README.md); rules can then treat mail from a sender you've never kept
# anything from differently. With -j, it also writes the senders of
# everything in Junk to JUNKFILE, for junked_senders_file.
set -euo pipefail

db=/var/lib/maddy/imapsql.db junked=
while getopts d:j: opt; do
    case $opt in
    d) db=$OPTARG ;;
    j) junked=$OPTARG ;;
    *) exit 64 ;;
    esac
done
shift $((OPTIND - 1))
if [[ $# != 2 ]]; then
    sed -n '3,/^set/{/^set/d;s/^# \{0,1\}//;p}' "$0" >&2
    exit 64
fi
account=$1 out=$2
[[ $account =~ ^[[:alnum:]._%+@-]+$ ]] || { echo "unexpected account name: $account" >&2; exit 64; }

# json_each gives the decoded values of a header field. The field as a whole
# would come out as JSON text, with < written as \u003c.
values() {
    echo "select h.value from msgs x join mboxes m on m.id = x.mboxId, json_each(cast(x.cachedHeader as text), '\$.$1') h
          where m.uid = (select id from users where username = '$account')"
}
# Writes the addresses in the header values a query returns to a file
addresses() {
    sqlite3 -readonly "$db" "$1" |
        { grep -oE '[[:alnum:]._%+=-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' || true; } | tr '[:upper:]' '[:lower:]' | sort -u > "$2.tmp"
    mv "$2.tmp" "$2"
    echo "$(wc -l < "$2") addresses in $2" >&2
}
addresses "
    $(values From) and m.name not in ('Junk', 'Not interested', 'Suspicious', 'Trash', 'Drafts', 'Sent')
    union all $(values To) and m.name = 'Sent'
    union all $(values Cc) and m.name = 'Sent'" "$out"
[[ -z $junked ]] || addresses "$(values From) and m.name = 'Junk'" "$junked"
