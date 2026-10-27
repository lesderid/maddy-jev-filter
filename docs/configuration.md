# Configuration

The config is `/etc/maddy/jev-filter.json`. `jev-filter.example.json` is a
complete one to start from.

## Settings

- `api_key_file`: the file with the Jev API key.
- `model` should be a versioned ID such as `jev-1.14.0`. Thresholds are
  tuned against one model, and aliases like `jev-latest`, the default, move
  to new ones.
- `timeout_seconds`: how long to wait for Jev (default 10).
- `max_body_chars`: how much of the body Jev sees (default 6000; the example
  uses 4000).
- `endpoint`: the Jev API URL, if not TypeSafe's.
- `authserv_id` is the host name maddy puts in its Authentication-Results and
  Received fields (its `hostname`). Without it, the topmost fields are used.
- `kept_senders_file` and `junked_senders_file` are lists of addresses like
  `update-kept-senders.sh` writes; see
  [Learning from your mailbox](learning.md). With them, the filter adds the
  `sender_kept` and `sender_junked` facts.
- `questions` and `rules`: see below.

## Questions

`questions` go to Jev as they are. See the
[Jev docs](https://docs.typesafe.ai/primitives.md) for `noul` (yes/no,
answered with a probability), `choice` and `score` questions.

Anywhere in a question, `{"include": "FILE"}` is replaced with the JSON in
FILE, or an empty list if it doesn't exist yet.
`{"include_for_sender": "FILE"}` takes a list like `update-examples.sh`
writes and is replaced, for each message, with only the entries from its
sender. That's how the Not interested examples get in.

## Rules

`rules` decide what happens. The first rule whose conditions all hold wins;
without a match the message stays in INBOX. Each rule has:

- `id`: short and header-friendly, such as `spam-certain`;
- `description`: in words, for the action header (and a UI one day);
- `folder`: where the message goes (none means INBOX);
- `flags`: IMAP flags to add, such as `\Seen` to mark it as read;
- `when`: the conditions. Each can set `min` and/or `max`, applied to the
  yes-probability of a `noul`, the value of a `score`, or, with
  `"choice": "..."`, the probability of that option of a `choice`.

Rules can also use facts, which the filter knows without asking Jev:
`sender_kept` and `sender_junked`, 1 if you've kept (or junked) mail from the
sender, 0 if not. A condition on a fact is false while the fact is unknown,
for example without its file.

## The example config

The example config was tuned on the author's mail (see
[eval/NOTES.md](../eval/NOTES.md)). It leans towards leaving spam in INBOX
over junking real mail. Its rules, in order:

| Rule | Folder | When |
|---|---|---|
| `not-interested` | Not interested, read | not_interested ≥ 0.9 |
| `phishing-certain` | Junk, read | phishing ≥ 0.95 |
| `phishing-spam` | Junk, read | phishing ≥ 0.85 and spam ≥ 0.9, unless transactional > 0.5 (real sign-in codes and delivery notices can look phishy) |
| `spam-certain` | Junk, read | spam ≥ 0.95, personal and transactional ≤ 0.3, not a newsletter (topic newsletters ≤ 0.8) |
| `spam-certain-newsletter` | Junk, read | spam ≥ 0.98, personal and transactional ≤ 0.3 (discount newsletters from small shops reach 0.96) |
| `spam-new-sender` | Junk, read | spam ≥ 0.85, personal and transactional ≤ 0.3, from a sender you never kept mail from |
| `spam-junked-sender` | Junk, read | spam ≥ 0.5, personal and transactional ≤ 0.3, from a sender with mail in Junk and none kept |
| `spam-likely` | Suspicious | spam ≥ 0.9, personal and transactional ≤ 0.3 |
| `phishing-likely` | Suspicious | phishing ≥ 0.8 |
| `sports` | Sports | topic sports ≥ 0.8 |

On a sample of about 2,000 spam messages and 3,600 real ones:

| | Junk | Suspicious | INBOX |
|---|---|---|---|
| Spam | 96.0% | 0.6% | 3.4% |
| Real mail | 0 | 8 | 3,587 |

The spam is 1,997 messages from Junk and 5 archived ones that turned out to
be spam. For the facts, only mail from before each message counts. Without
`spam-new-sender` and `spam-junked-sender` it's 94.0%, 2.1% and 3.9%, also
with no real mail junked.

The real mail in Suspicious is mostly notices that look like phishing (a
failed card charge, a security alert) and marketing. Much of the Junk the
rules leave is newsletters from real companies; put those in Not interested
or sort them yourself.

The `sports` rule hasn't been tested. It's an example of routing by topic:
add an option to the `topic` question and a rule that uses it.

The phishing question names the recipient's own domains (example.org, …),
so that mail claiming to come from their own mail server counts as
phishing. Change those for another server.
