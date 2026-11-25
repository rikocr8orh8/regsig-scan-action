"""Fake Regulatory Signals API for tests. Usage: mock_server.py PORT REQUEST_LOG CASE
Every request is appended as one JSON line to REQUEST_LOG. No network access beyond 127.0.0.1."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def checks(**kw):
    base = {"hasRateLimiting": True, "resOkViolationCount": 0, "webhookSilentSuccess": False, "paymentWebhookVerified": None,
            "buttonRouteGapCount": 0, "stripeWebhookVerified": None, "rlsTablesEnabled": False, "rlsPoliciesFound": False,
            "aiProviders": [], "agenticFrameworks": []}
    base.update(kw)
    return {"mode": "deterministic", "checks": base}

CLEAN = checks()
BAD = checks(hasRateLimiting=False, resOkViolationCount=3, webhookSilentSuccess=True, paymentWebhookVerified=False,
             rlsTablesEnabled=True, rlsPoliciesFound=True, aiProviders=["anthropic"])
# case -> list of (status, raw body, delay seconds); the last entry repeats
CASES = {
    "clean": [(200, json.dumps(CLEAN), 0)],
    "bad": [(200, json.dumps(BAD), 0)],
    "unauth": [(401, json.dumps({"error": "Invalid or revoked API key"}), 0)],
    "r429": [(429, json.dumps({"error": "Rate limited"}), 0)],
    "r500": [(500, "<html>Internal Server Error</html>", 0)],
    "flaky": [(503, "{}", 0), (200, json.dumps(BAD), 0)],
    "badjson": [(200, "<html>not json</html>", 0)],
    "empty": [(200, "{}", 0)],
    "checks_array": [(200, json.dumps({"checks": []}), 0)],
    "evil_error": [(401, json.dumps({"error": "x\n::error::injected\n::add-mask::y `tick` <b>"}), 0)],
    "evil_fields": [(200, json.dumps(checks(aiProviders=["a|b\n# Heading <img src=x onerror=1>", "`code`"], hasRateLimiting="yes|\n::error::boom",
                                            resOkViolationCount="9")), 0)],
    "string_counts": [(200, json.dumps(checks(resOkViolationCount="3", buttonRouteGapCount="2")), 0)],
    "providers_string": [(200, json.dumps(checks(aiProviders="anthropic")), 0)],
    "boundary": [(200, json.dumps(checks(resOkViolationCount=-1, buttonRouteGapCount=1)), 0)],
    "boundary0": [(200, json.dumps(checks(resOkViolationCount=0, buttonRouteGapCount=0)), 0)],
    "huge": [(200, json.dumps(dict(checks(), pad="x" * 6000000)), 0)],
    "slow": [(200, json.dumps(CLEAN), 4)],
}
PORT, LOG, CASE = int(sys.argv[1]), sys.argv[2], sys.argv[3]
count = 0

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        global count
        n = int(self.headers.get("Content-Length", 0)); raw = self.rfile.read(n)
        try: body = json.loads(raw)
        except Exception: body = None
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "key": self.headers.get("X-RegulatorySignals-Key"), "ctype": self.headers.get("Content-Type"), "body": body}) + "\n")
        seq = CASES[CASE]; status, payload, delay = seq[min(count, len(seq) - 1)]; count += 1
        time.sleep(delay)
        try:
            self.send_response(status); self.send_header("Content-Type", "application/json"); self.end_headers()
            self.wfile.write(payload.encode())
        except (BrokenPipeError, ConnectionResetError): pass
    def log_message(self, *a): pass

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
