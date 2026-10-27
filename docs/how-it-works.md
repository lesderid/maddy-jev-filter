# How it works

`maddy-jev-filter.d` is a D program, run by `rdmd` through its shebang. The
code is in the `jevfilter` package next to it. maddy runs it twice per
message.

## The two stages

1. **`check`**, as a `check.command` in the pipeline that delivers to local
   mailboxes, once per message. It sends the message to Jev and asks the
   questions in the config. Then it applies the rules and prints two header
   fields, which maddy adds to the top of the message:

   ```
   X-Maddy-Jev-Filter: id=8f1c0e2a; not_interested=0.050; personal=0.012; phishing=0.031; spam=0.981; topic=shopping:0.870; transactional=0.020; sender_kept=no; sender_junked=yes; model=jev-1.14.0; rcpt=shop@example.org
   X-Maddy-Jev-Filter-Action: id=8f1c0e2a; folder=Junk; read=yes; rule=spam-certain; version=4f2a9c81d0e3
   ```

   The first has Jev's answers, whether you've kept or junked mail from the
   sender before (`sender_kept`, `sender_junked`, see
   [Learning from your mailbox](learning.md)), and `rcpt` with the envelope
   recipients before any rewriting, which maddy doesn't store otherwise.

   The second is the decision: the folder (`INBOX` if no rule matched),
   whether the message is marked as read, any other `flags`, the `rule` that
   decided (`none` if none did), and the commit the installed filter came
   from. Mail from logged-in users, and bounces maddy generates itself, is
   skipped.

2. **`route`**, as an `imap.filter.command` on the mailbox storage, once per
   local recipient. It carries out the decision in the second header: maddy
   stores the message in that folder with those flags.

The `id` is maddy's internal message ID. Senders can't know it, so `route`
ignores any such headers a sender adds themselves. Anything else that reads
these headers, such as a UI, should check the `id` the same way, or only
trust the topmost ones.

## Failures

Failures never cost mail. If Jev is down, slow (over `timeout_seconds`) or
rate-limiting, or the config is broken, the first header carries
`error=...` and the second says
`folder=INBOX; read=no; rule=none; error=yes`. `check` retries once on
429/529 and connection errors.

## What Jev sees

For each message Jev gets this JSON `state` (`maddy-jev-filter.d state FILE`
prints it):

- `from`, `reply_to`, `to`, `cc` and `subject`, decoded. `to` includes the
  address the mail was sent to, so per-service aliases are visible.
- `body`: the HTML part converted to text, or the plain-text part when there
  is no HTML, cut to `max_body_chars`.
- `attachments`: file names and types.
- `link_domains`: the hosts of up to 20 links. For
  `https://paypal.com@evil.example/` that is `evil.example`.
- `authentication`: what maddy verified, from its own Authentication-Results
  field, for example
  `spf=pass (em.shop.example); dkim=pass (shop.example); dmarc=pass (shop.example)`.
- `sending_server`: the server that handed the message to maddy, from
  maddy's own Received field, for example `o1.mail.shop.example`.

Only the topmost Authentication-Results and Received fields count, which
maddy adds itself, and with `authserv_id` set only those with that host
name. Senders can add such fields too, but further down. Jev doesn't see the
other headers, which senders write themselves and which are mostly noise.

The envelope recipient isn't shown to Jev yet. maddy doesn't store it, so
there's nothing to test a question about it on; the `rcpt` in the header
changes that for new mail.

## Logs

The script logs to syslog (facility mail, tag `maddy-jev-filter`). There is
one line per stage per message, with metadata only:

```sh
journalctl -t maddy-jev-filter -f
```

```
check id=8f1c0e2a; ...; model=jev-1.14.0; rcpt=shop@example.org; action folder=Junk; read=yes; rule=spam-certain; version=4f2a9c81d0e3; tokens=1312; 284ms; sender=bounce@mailer.example; from=Deals <deals@example.com>; subject=Last chance: 70% off; message_id=<...>
route id=8f1c0e2a; folder=Junk; flags=\Seen
```
