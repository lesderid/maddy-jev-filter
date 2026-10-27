# Development

## Code

- `maddy-jev-filter.d`: the command line, and the `check` and `route` stages.
- `jevfilter/config.d`: the config file, includes, rules and facts.
- `jevfilter/jev.d`: the Jev request, and turning answers into a folder.
- `jevfilter/message.d`: what Jev sees of a message.
- `jevfilter/mime.d`: header fields, multipart, transfer encodings, charsets.
- `jevfilter/text.d`: HTML to text, link domains, whitespace.
- `jevfilter/examples.d`: matching senders, for Not interested and the
  sender lists.
- `jevfilter/eval.d`: the `classify` and `report` modes.
- `jevfilter/util.d`: header-safe values, logging, the filter version.
- `tools/`: installing, the timers' scripts, and classifying and moving
  stored mail.
- `dist/`: systemd units for the timers.
- `eval/`: the notes on every experiment, and the config of each version.
- `docs/infographic.svg`: drawn by `tools/infographic.py`.

## Tests

`test/run.sh` runs both stages, `classify` and `report` against the test
messages, and the unit tests. It uses `test/mock-jev.py` in place of Jev, so
no API key is needed:

```sh
bash test/run.sh
```

To test a build other than the script itself, such as one made with `gdc`
on a machine without `rdmd`, point `FILTER` at it:

```sh
gdc -I. -o /tmp/mjf maddy-jev-filter.d jevfilter/*.d
FILTER=/tmp/mjf bash test/run.sh
```

## Infographic

`tools/infographic.py` draws `docs/infographic.svg`, with the numbers from
the README written into it. To redraw it after they change, get Fredoka's
variable font (see the script) and run:

```sh
tools/infographic.py Fredoka.ttf docs/infographic.svg
```
