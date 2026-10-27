#!/usr/bin/env python3
"""Stand-in for the Jev API, for testing maddy-jev-filter without an API key.

POST /v1/systemone  answers every question: noul 0.93, the first choice at 0.9,
                    score 1.5
POST /error         HTTP 422 with a validation error
POST /unauthorized  HTTP 401, as for a revoked API key
POST /slow          sleeps 10 seconds, to test timeouts

Each request body is written to the directory given as the second argument.
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

port = int(sys.argv[1])
dump_dir = Path(sys.argv[2])
dump_dir.mkdir(parents=True, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        count = len(list(dump_dir.iterdir()))
        (dump_dir / f"{count:03}.json").write_text(json.dumps(request, indent=2, ensure_ascii=False))

        if self.path == "/slow":
            time.sleep(10)
        if self.path == "/error":
            return self.reply(422, {"detail": [{"loc": ["body", "state"], "msg": "Field required", "type": "missing"}]})
        if self.path == "/unauthorized":
            return self.reply(401, {"detail": {"error_type": "authentication_error", "message": "Cannot authenticate"}})

        answers = {}
        for name, question in request["questions"].items():
            if question["type"] == "noul":
                answers[name] = {"type": "noul", "noul": 0.93}
            elif question["type"] == "choice":
                options = list(question["criteria"])
                probabilities = {option: 0.1 / max(len(options) - 1, 1) for option in options[1:]}
                probabilities[options[0]] = 0.9
                answers[name] = {"type": "choice", "choice": options[0], "confidence": 0.8, "probabilities": probabilities}
            elif question["type"] == "score":
                answers[name] = {"type": "score", "score": 1.5, "confidence": 0.5, "legend": {}, "probabilities": {}}
        self.reply(200, {"model": "jev-mock-1.0", "answers": answers, "usage": {"input_tokens": 1, "output_tokens": 1}})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
