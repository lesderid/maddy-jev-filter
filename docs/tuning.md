# Tuning on existing mail

`classify` runs the questions over stored messages. `report` then applies the
rules to those answers again, without calling Jev, so thresholds and rules
can be changed and re-checked for free. Only changing the questions, the
model, `max_body_chars` or the Not interested examples needs a new
`classify` run. `report` warns when results come from a different config.

On the mail server, as the maddy user:

```sh
lib=/usr/local/lib/maddy-jev-filter
eval=/var/lib/maddy/jev-eval/v1
cd /var/lib/maddy

# Classify a sample of spam and of real mail. -n always picks the same sample.
$lib/tools/classify-mailbox.sh -n 500 user@example.org Junk $eval/junk
$lib/tools/classify-mailbox.sh -n 500 user@example.org Archive.2026 $eval/archive-2026

# Where would they go, and how are the answers spread?
$lib/maddy-jev-filter.d report $eval/*

# Real mail that would be junked (false positives), spam that would stay (false negatives)
$lib/maddy-jev-filter.d report --list=Junk $eval/archive-2026
$lib/maddy-jev-filter.d report --list=INBOX $eval/junk
```

Use `report` for numbers rather than jq on the result files; see
[eval/NOTES.md](../eval/NOTES.md) for why. Once a config does well on the
sample, check it on messages it wasn't tuned on before trusting it. `-s`
picks a different sample and `-x` leaves out the messages in an earlier
results directory:

```sh
$lib/tools/classify-mailbox.sh -n 500 -s holdout -x $eval/archive-2026 user@example.org Archive.2026 $eval/holdout/archive-2026
```

Jev's answers vary by a few hundredths between runs, so one or two messages
crossing a threshold between versions doesn't mean much. `eval/NOTES.md` has
what was tried so far and what it showed.

## Iterating

- **Too much real mail junked:** raise the thresholds, or add conditions
  that rule it out, like the `personal`/`transactional` limits.
- **Wrong answers:** the Jev docs suggest writing down why the answer is wrong
  and adding that to the question's `criteria`. Then classify the same sample
  into a new directory and compare the reports.
- **Bad labels:** Junk and the archive are not perfectly labelled. Move
  misfiled messages to the right folder and the next run will use the
  corrected label.

To move messages, for example everything in Junk that the rules would leave
in INBOX, into a folder for manual triage:

```sh
$lib/maddy-jev-filter.d report --list=INBOX $eval/junk |
    $lib/tools/move-messages.sh user@example.org "Triage.Junk"
```
