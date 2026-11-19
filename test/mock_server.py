import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
CASES = {
 "clean": (200, {"mode":"deterministic","checks":{"hasRateLimiting":True,"resOkViolationCount":0,"webhookSilentSuccess":False,"paymentWebhookVerified":None,"buttonRouteGapCount":0,"stripeWebhookVerified":None,"rlsTablesEnabled":False,"rlsPoliciesFound":False,"aiProviders":[],"agenticFrameworks":[]}}),
 "bad":   (200, {"mode":"deterministic","checks":{"hasRateLimiting":False,"resOkViolationCount":3,"webhookSilentSuccess":True,"paymentWebhookVerified":False,"buttonRouteGapCount":0,"stripeWebhookVerified":None,"rlsTablesEnabled":True,"rlsPoliciesFound":True,"aiProviders":["anthropic"],"agenticFrameworks":[]}}),
 "unauth": (401, {"error":"Invalid or revoked API key"}),
}
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = json.loads(self.rfile.read(n))
        open(sys.argv[2], "w").write(json.dumps({"path": self.path, "key": self.headers.get("X-RegulatorySignals-Key"), "body": body}))
        status, payload = CASES[sys.argv[3]]
        self.send_response(status); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(payload).encode())
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
