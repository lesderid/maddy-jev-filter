# Learning from your mailbox

Jev only sees one message at a time. Your mailbox knows more: what you've
said you don't want, who you've kept mail from, and what you've moved to
Junk. Two timers turn that into something the filter can use.

## Not interested

Some mail isn't spam but still unwanted: newsletters you never signed up for
or can't unsubscribe from, or notifications from a service you no longer
want to hear from. Jev can't know that from the message alone, so these
can't be caught by tuning the spam questions without catching wanted mail
too.

Instead, drag such mail into a **Not interested** folder. Every 15 minutes,
`tools/update-examples.sh` turns that folder into a list with one entry per
sender address: the sender, the address it was sent to, and the subjects of
up to 25 of their newest messages there.

For each incoming message, the filter picks the entries from the same
sender: the same address, the same domain (`email3.example.com` counts as
`example.com`), or the same display name unless it's generic like
"noreply". At free mail providers such as Gmail, only the same address
counts. Only those entries go to Jev, usually none, so the folder can grow
without making every request bigger. The `not_interested` question then
asks whether the message is the same kind of email as the subjects listed
for its sender. It's part of the same request as the other questions, and
its rule comes first.

A shop's newsletters in Not interested then don't catch its order
confirmations too, unless you put those there as well. A match of 0.9 or
more goes into Not interested itself, marked as read, and becomes an example
too: a wrong match teaches the filter until you move it out. Moving a
message out of Not interested takes it off the list.

In a test on 1,258 messages in Not interested from 247 senders, the newest
message of each sender with more than one was held out:

- Of 18 with a subject seen before, 18 were caught.
- Of 70 with a new subject, 36 were caught at 0.9 (51 at 0.8).

Real mail from those senders scored high when it was the same kind as the
examples, and low when it wasn't (an e-invoicing notice next to a marketing
example: 0.83; an identity verification notice: 0.60).
`maddy-jev-filter.d questions MESSAGE` shows which entries a message would
get.

Set it up on the mail server:

```sh
sudo -u maddy /usr/local/bin/maddy imap-mboxes create user@example.org "Not interested"
sudo cp /usr/local/lib/maddy-jev-filter/dist/maddy-jev-filter-not-interested.* /etc/systemd/system/
sudo systemctl enable --now maddy-jev-filter-not-interested.timer
```

The service runs the script for `user@example.org`; edit the account in the
unit file for another setup. A message whose sender has entries costs about
500 tokens more; in the test, about a fifth of real mail had such a sender.

## Senders you've kept or junked mail from

Spam often comes from domains made up for one campaign, and Jev can't tell
those from a small shop's real newsletter: both are marketing from a domain
it doesn't know. Your mailbox can. Every 15 minutes,
`tools/update-kept-senders.sh` lists the senders of all mail outside Junk,
Not interested, Suspicious, Trash and Drafts, and everyone you've written to
from Sent. It reads maddy's database directly and takes a couple of seconds.

The filter then records `sender_kept=yes` or `no` for each message, matching
the sender the same way as Not interested: by domain, or by address at free
mail providers. The `spam-new-sender` rule junks probable spam (0.85) from
senders you've never kept mail from. Moving a message out of Junk or
Suspicious makes its sender known.

Junk teaches the filter too. With `-j`, the same script lists the senders of
everything in Junk, and the filter records `sender_junked`. The
`spam-junked-sender` rule junks mail that may be spam (0.5) from a sender
with mail in Junk and none you kept, such as a filing service that keeps
writing to an address it found in a business register. Mail the filter put
in Junk counts too, so a wrong decision repeats itself until you move the
message out, which makes the sender kept and turns the rule off for them.

This works best if you rarely delete mail. A new shop's first newsletter can
land in Junk if Jev scores it as spam, unless you kept something from the
shop before, such as its sign-up confirmation. Mail with a forged From
address of a sender you know isn't caught by these rules, but the others
still apply. Without the lists, `sender_kept` and `sender_junked` are missing
from the header and rules that use them never match.

Set it up on the mail server:

```sh
sudo cp /usr/local/lib/maddy-jev-filter/dist/maddy-jev-filter-kept-senders.* /etc/systemd/system/
sudo systemctl enable --now maddy-jev-filter-kept-senders.timer
```
