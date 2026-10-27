#!/usr/bin/env bash
# Runs both stages against the test messages, using test/mock-jev.py instead of Jev.
#
#   test/run.sh            uses ./maddy-jev-filter.d (needs rdmd)
#   FILTER=path test/run.sh  uses another build of the filter
set -euo pipefail

cd "$(dirname "$0")/.."
filter=${FILTER:-./maddy-jev-filter.d}
port=${PORT:-8099}
work=$(mktemp -d)
trap 'kill $mock 2>/dev/null; rm -rf "$work"' EXIT

python3 test/mock-jev.py "$port" "$work/requests" &
mock=$!
sleep 0.5

echo "test-key" > "$work/key"
config() {
    sed -e "s|/etc/maddy/jev-filter.key|$work/key|" \
        -e "s|\"model\"|\"endpoint\": \"http://127.0.0.1:$port$1\", \"model\"|" \
        -e "s|\"timeout_seconds\": [0-9]*|\"timeout_seconds\": 3|" \
        jev-filter.example.json > "$work/config.json"
}

# check, then route the message with the check header prepended, like maddy does
deliver() {
    local id=$1 message=$2
    local header
    header=$("$filter" --config="$work/config.json" check "$id" --sender=-sender@example.com \
        --rcpts=$'shop@example.org\nother@example.org' --auth-user= --source-ip=192.0.2.25 < "$message" 2>/dev/null)
    echo "  header: $header"
    echo "  folder: '$( { echo "$header"; cat "$message"; } | "$filter" route "$id" 2>/dev/null)'"
}

show_state() {
    python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["state"], indent=2, ensure_ascii=False))' \
        "$work/requests/$(ls "$work/requests" | tail -1)" | sed 's/^/  /'
}

config /v1/systemone
for message in test/messages/*.eml; do
    echo "$message"
    deliver "msg$RANDOM" "$message"
    show_state
done

echo "route without a check header for this delivery (the forged one has another id)"
echo "  folder: '$("$filter" route msg1 < test/messages/forged.eml 2>/dev/null)'"

echo "Jev returns an error"
config /error
deliver error1 test/messages/plain.eml

echo "Jev times out"
config /slow
time deliver slow1 test/messages/plain.eml

echo "skipped: a logged-in user, and a bounce maddy generated (expected: no header)"
echo "  '$("$filter" --config="$work/config.json" check skip1 --auth-user=user@example.org --source-ip=192.0.2.1 < test/messages/plain.eml 2>/dev/null)'"
echo "  '$("$filter" --config="$work/config.json" check skip2 --auth-user= --source-ip= < test/messages/plain.eml 2>/dev/null)'"

echo "missing config"
"$filter" --config=/nonexistent check missing1 < test/messages/plain.eml 2>/dev/null
echo "  exit code: $?"

echo "classify, from a file and from stdin"
config /v1/systemone
"$filter" --config="$work/config.json" classify --tag=test/plain test/messages/plain.eml
"$filter" --config="$work/config.json" classify --tag=test/stdin - < test/messages/forged.eml

echo "unit tests"
rdmd -unittest --main -I. jevfilter/examples.d && rdmd -unittest --main -I. jevfilter/text.d && echo "  passed"

echo "rules, applied by report to test/results.jsonl"
echo "  expected: phishing, spam, new-sender and junked-sender to Junk; not-interested to Not interested; newsletter, phishing-but-transactional and likely to Suspicious; sports to Sports; spam-but-personal, new-sender-but-kept and junked-but-kept to INBOX; 1 unusable, 1 error"
"$filter" --config="$work/config.json" report --list=Junk --list=Suspicious --list=Sports --list=INBOX test/results.jsonl 2>&1 | sed 's/^/  /'
