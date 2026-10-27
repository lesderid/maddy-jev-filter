# Evaluation notes

Configs in this directory are the versions tried, in order. Results are on
the mail server in `/var/lib/maddy/jev-eval/VERSION` (tuning sets) and
`VERSION-holdout` (held-out sets).

## Data

- **Tuning:** the same 500 random messages from each of Junk, Old.Junk (old)
  and Archive.2026 for every version (`classify-mailbox.sh -n 500`).
- **Held out:** 500 other messages each from Junk, Old.Junk and Archive.2026
  (`-s holdout -x` the tuning sample), 500 each from Archive.2025 and
  Archive.2024, and all of INBOX, Travel, Jobs, Docs and Later (106).
- Junk and Old.Junk count as spam, the rest as real mail. The labels are
  noisy both ways:
  - Junk holds newsletters from real companies (a crypto exchange, a game
    shop, a consumer organisation, an email provider). The filter
    deliberately leaves those alone; sorting newsletters is a manual job.
  - The archive holds a little spam: game promos from throwaway domains,
    and two cold excavator pitches in INBOX.
- Newsletters is left out on purpose.

Jev is nearly deterministic. Of 500 repeated answers, 230–410 were
identical, and almost all of the rest differed by at most 0.05. A message or
two crossing a threshold between versions is noise.

## Versions

Each line is the share of spam caught, then real mail junked, with that
version's rules.

- **v1** (`jev-filter.example.json` at the time): 86% caught, 3/500 junked.
  - Phishing fired on ordinary shop newsletters (0.90–0.96), probably
    because of the hint about link domains.
  - Cold B2B outreach (a fake "Re:" offering a factory's products) stayed
    at spam 0.86–0.89.
  - Fake purchase orders and invoices looked personal (0.75–0.85).
- **v2**: rewrote spam (cold B2B outreach, fake "Re:" replies, real shops'
  promotions are not spam), phishing (fake invoices and purchase orders;
  tracking links are not a sign) and personal (strangers are not personal).
  95% caught, 3/500 junked.
- **v3**: phishing flags a sender domain that doesn't fit the company in the
  sender name, and anything claiming to be from the recipient's own mail
  server. Three rules, the new one phishing ≥ 0.85 with spam ≥ 0.9.
  95.5% caught, 0/500 junked.
- **v4**: added `legit_sender` (a real company writing from its own domain).
  It separates the tuning sets well (93% of spam ≤ 0.3, 0.6% of real mail),
  but on held-out mail real senders with no-reply domains score low (train
  tickets 0.11–0.19, a government immigration service 0.14). A rule on it
  junked a genuine arrival card notice from that service, so it's not used.
  - With the v3 rules on held-out mail: 6/1606 junked. Two were real
    mistakes: a small shop's newsletter (spam 0.96) and a fast-food app's
    verification code (spam 0.96, phishing 0.94).
  - Better rules: the phishing + spam rule needs transactional ≤ 0.5, and a
    newsletter (topic newsletters > 0.8) needs spam ≥ 0.98. On tuning and
    held-out together: 92% of spam caught, and the only real mail junked was
    the two excavator pitches.
- **v5**: drops `legit_sender`.
  Phishing says that mail which only delivers a code, ticket or confirmation
  isn't phishing unless it asks the recipient to log in, pay or hand over
  data. Uses the v4 rules.
  - Phishing on real codes and tickets went down: train tickets from about
    0.70 to 0.55, the arrival card from 0.91 to 0.81, another service's
    code from 0.79 to 0.68. The fast-food app's code is still at phishing
    0.90 and spam 0.97. It isn't in English, is from "noreply", asks whether
    the recipient just tried to log in, and links through a URL shortener.
    The transactional veto keeps it out.
  - Final results from `report`, on tuning, held-out and 1,500 more
    messages from Archive.2021–2023 (`v5-final`):
    - 1874/2000 Junk caught (93.7%).
    - 2/3601 real mail junked: a game promo from a throwaway domain, and a
      guest post proposal for one of the recipient's domains, sent from an
      unrelated company's domain. Both are really spam.
    - The closest calls it got right: a crypto exchange's security email
      (phishing 0.92), an online marketplace's delivery notices, and
      newsletters at spam 0.96–0.97 that the newsletter rule kept.
  - What it misses: about 47 messages Jev reads as legitimate (mostly
    newsletters from real companies), newsletters with spam 0.95–0.98, cold
    outreach at spam 0.9–0.95, and phishing at 0.85–0.95 that looks
    transactional.
- **v6**: v5 plus `dubious_offer` (replica goods, miracle cures, crypto and
  gambling schemes, fake rewards, bulk B2B offers). It separates well (71% of
  spam ≥ 0.8, 4/2101 real mail), but the extra catches are newsletters, and
  a small shop's clearance sale newsletter scored 0.91.
  With a guard for newsletters it adds only about 10 catches in 2000, so it
  isn't used.

- **v7**: v5 plus `blocked`, which
  compares a message with examples built from the Blocked folder (see the
  README), and a rule sending blocked ≥ 0.9 to Junk. Answers to the other
  questions are unchanged: Jev answers each question independently.
  - Test (`blocked-test` on the mail server): three newsletters as examples
    (two shops' sales and a cashback app's weekly newsletter).
    - Other issues of those newsletters: 0.88–0.98, 7/8 to Junk.
    - Other mail from the cashback app: verification code 0.11, statement
      0.27, support reply 0.15, bank connection 0.52, gift card offers
      0.55–0.68, cashback promo 0.74.
    - 40 unrelated real messages: at most 0.18. 20 spam: at most 0.23.
    - With no examples at all: 0.05–0.08.
  - Still to do: an evaluation on the real Blocked folder once it has been
    filled, holding out half of it as test messages.

- **v8**: v5 plus two state fields: `authentication`, from maddy's own
  Authentication-Results, and `sending_server`, from its own Received field.
  Phishing criteria explain dmarc=pass, and call failing authentication for
  a well-known company's domain a sign. For production, the check moves to
  the `local_routing` pipeline, where maddy has added both fields.
  - Real mail with phishing ≥ 0.8 went from 11 to 7, and ≥ 0.5 from 110 to
    57. The fast-food app's code dropped to 0.55 and 0.20, train tickets to
    about 0.05, the marketplace's notices to about 0.1.
  - But seven genuine senders that fail DMARC rose to 0.77–0.89: shops, a
    mobile carrier and others that send through SendGrid, Mailgun or
    MailerLite without alignment.
- **v9** (deployed with `blocked`): v8 without
  the "failing authentication is a sign" sentence, and saying that a
  failing check alone is common for small or badly configured senders.
  - Measured by asking only the changed phishing question and putting the
    answers into the v8 results (`v9-phishing`, `v9-merged`). That works
    because Jev answers each question independently.
  - On the same messages:
    - Junk caught (of 1,997): v5 1,874, v8 1,877, v9 1,880.
    - Real mail junked (of 3,600): v5 2, v8 1, v9 1 (the SEO pitch).
    - Real mail with phishing ≥ 0.8: 11, 7, 5. With phishing ≥ 0.5: 110,
      57, 43.
  - The DMARC-failing senders are back down (two of the shops 0.82 → 0.16
    and 0.78 → 0.10). The highest phishing on real mail is 0.91, a KYC
    check from a gambling site.

- **v10**: v9 with tiers, plus a yes/no question for a personal category of
  notifications, routed to its own folder (left out of this copy). Rules
  have ids, descriptions and flags. Junk rules mark mail as read;
  Suspicious (`spam-likely`: spam ≥ 0.9 and not personal or transactional;
  `phishing-likely`: phishing ≥ 0.8) and that folder leave it unread.
  - With the v9 answers (no `blocked` rule and none for the
    personal-category question, since those results have no answers for
    them):
    - Junk sample (1,997): 94.1% to Junk, 2.0% to Suspicious, 3.9% INBOX.
    - Real mail (3,600): 1 to Junk, 10 to Suspicious.

- **v11**: v10 with `blocked`
  renamed to `not_interested` (folder Not interested, rule
  `not-interested`). Jev doesn't see question names, so only the examples'
  key in the instructions changed.

- **v12**: Not interested examples
  grouped by sender, up to 25 subjects each, and per message only the
  entries of its sender (`include_for_sender`). The flat list of 200 sent
  everything (13,600 tokens per request) and covered only 136 of 247
  senders.
  - Test (`ni-test` on the mail server, only the `not_interested`
    question). Held out the newest message of each of the 88 senders with
    more than one:
    - 18 with a subject seen before: all ≥ 0.9.
    - 70 with a new subject: 36 ≥ 0.9, 51 ≥ 0.8, 63 ≥ 0.5.
  - 400 archived messages from the same addresses or domains (10,062 in
    all): 66 ≥ 0.9. Nearly all of them are the same kind as an example the
    user put in Not interested (a university's tuition reminders, a taxi
    app's terms updates, promotions from a game shop and an online course
    platform), archived before the user changed their mind, so this isn't
    a clean set of mail to keep.
    - Different kinds stayed low: an e-invoicing notice 0.83 (the example
      was marketing), a crypto exchange's identity verified notice 0.60, a
      bank's interest notices 0.54–0.60.
  - Requests with examples averaged 1,200 tokens for this one question,
    against 690 without.
  - The first version matched any gmail.com sender to one in the list; at
    free mail providers only the address counts now.

- **v13**: rule `spam-new-sender`,
  spam ≥ 0.85, personal and transactional ≤ 0.3, and the `sender_kept` fact
  0: no mail from the sender's domain (address at free mail providers) in
  any folder but Junk, Not interested, Suspicious, Trash, Sent and Drafts,
  and none of it sent to them. Same questions, so no Jev calls: simulated on
  the v9 answers, with the dates from maddy's database and counting only
  mail kept before each message.
  - Junk sample (1,997): 1,885 from senders never kept before, 55 kept, 57
    not found by Message-ID. 24 more to Junk at spam ≥ 0.9, 32 at 0.85, 33
    at 0.8.
  - Real mail (3,600): 3,447 from senders kept before, 151 never. 2 more to
    Junk at 0.9, 4 at 0.85: two game ads from throwaway domains, an empty
    Gmail message from a stranger and a cold "can I get your feedback"
    pitch, all archived spam.
  - Prompted by a watch ad from a throwaway domain with spam 0.94 and
    newsletters 0.99, which `spam-certain-newsletter` (0.98) let through to
    Suspicious.
  - All live rules, applied in Python (without the fact it gives the same
    numbers as `report`): Junk sample 95.7% Junk, 0.7% Suspicious, 3.6% INBOX (was 94.1/2.0/3.9);
    real mail 5 Junk, 8 Suspicious, 3,587 INBOX (was 1/10/3,589).
    Suspicious is now mostly `phishing-likely` (12 of 13 from Junk, 5 of 8
    real: card failures, account verification); `spam-likely` only fires
    for known senders.
- **v14** (the current `jev-filter.example.json`): rule
  `spam-junked-sender`, spam ≥ 0.5, personal and transactional ≤ 0.3,
  `sender_kept` 0 and `sender_junked` 1 (mail from the sender in Junk).
  Prompted by a business filing service's annual report reminders to an
  address taken from a business register (spam 0.57–0.65, four of them,
  the first three moved to Junk by the user). Simulated like v13; the Junk
  dates are delivery dates, not when mail was moved there, so this is a bit
  optimistic.
  - Junk sample: of the 85 the other rules miss, 23 are from a sender with
    earlier mail in Junk. 6 more to Junk at spam ≥ 0.4, 4 at 0.5 (one of
    them a filing service reminder), 3 at 0.6. Total 95.9% Junk, 0.7%
    Suspicious, 3.4% INBOX.
  - Real mail: 2 of 3,600 are from a sender never kept and with mail in
    Junk; none would be junked at any of those thresholds.
  - The 5 real messages the rules junk (v10's SEO pitch and v13's four)
    were all archived spam. Counted as spam: spam (2,002) 96.0% Junk, 0.6%
    Suspicious, 3.4% INBOX; real mail (3,595) 0 Junk, 8 Suspicious. Without
    the two sender rules: 94.0%, 2.1% and 3.9%, also with no real mail
    junked.
  - Tried first, and not worth it:
    - A rule on "the recipient address never got mail that was kept"
      (from To/Cc; Delivered-To only has the rewritten address): at spam
      ≥ 0.6, 2 more from Junk and 2 real messages, newsletters to fresh
      per-service aliases.
    - A sentence in the spam question about per-service aliases ("a
      company writing to an address named after something else didn't get
      it from the recipient"), only the spam question, 22 messages: the
      filing service's reminders went from 0.57–0.65 to 0.64–0.73, and real
      mail to aliases rose by up to 0.1 as well.

- **Quarantined mail** (`quarantined/` on the mail server): maddy
  quarantined 24 messages for SPF, 6 for DMARC and 9 for missing MX records
  in a month (found by envelope sender and delivery time; 19 more MX ones
  look like probes that were never delivered). Classified with
  v13: all to Junk, except one MX one, a real Firebase sign-in mail the
  user had rescued, which goes to INBOX. SPF failures and missing MX
  records go to the filter since (`fail_action ignore`); DMARC still
  quarantines.

## Pitfalls

- Use `report` for numbers, not jq on the result files. Results written
  before the compact number output stored 0.98 as 0.979999999999999982,
  which jq 1.7 compares as a decimal: less than 0.98. Jev answers in
  hundredths, so answers exactly at a threshold are common.
- Don't trust a question just because it separates the tuning sample well;
  check it on held-out mail (see `legit_sender`).
- Since the full pass moved v5's misses into Triage.Junk and
  Triage.Old Junk, `classify-mailbox.sh -n 500 … Junk` picks different
  messages than before, and only ones v5 junked. Recall measured that way
  is just agreement with v5. To compare on the old sample, find the moved
  messages by Message-ID (`v8-same`).

## Cost

About 112M input tokens ($4.73) on the current key:
- $1.21 for v2–v6 and the first final check;
- $2.64 for the full pass over Junk and Old.Junk;
- $0.88 for v8, v9 and the test of the personal-category question.

Plus $0.09 for v1 on another key. A run over the tuning sample (1,500
messages) costs about $0.10.
