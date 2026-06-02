"""
api/chat.py

Vercel Python serverless function that proxies Vee Patron chatbot questions
to OpenAI. The OpenAI API key NEVER ships to the browser; it lives only in
Vercel environment variables (OPENAI_API_KEY). Optional override:
OPENAI_MODEL (default: gpt-4o-mini).

Request:  POST /api/chat   { "question": str, "context": dict }
Response: 200 { "answer", "model", "usage" }
          4xx/5xx { "error", "detail"? }

No third-party dependencies — uses Python stdlib only (json, os, urllib).
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler

# ----------------------------------------------------------------------- config
DEFAULT_MODEL       = "gpt-4o-mini"
MAX_QUESTION_CHARS  = 2000
MAX_CONTEXT_BYTES   = 256 * 1024          # hard cap on the JSON context payload
OPENAI_TIMEOUT_SEC  = 25                   # safety net; OpenAI usually answers in <5s
OPENAI_URL          = "https://api.openai.com/v1/chat/completions"

SYSTEM_PROMPT = (
    'You are "Vee Patron", a trade and logistics analyst for the Valency RCN '
    "Trade Eagle Eye control tower.\n\n"
    "You answer questions about RCN trade execution, origin dues, documents, "
    "quality, buyers, vessels, and risk using ONLY the JSON "
    "CONTEXT provided in the next system message.\n\n"
    "Rules:\n"
    "- Be concise, factual, and specific. Cite field names from the data when "
    "relevant.\n"
    "- Format numbers with thousand separators (e.g. 12,450 MT). Do not "
    "invent units.\n"
    "- For lists of shipments use a short markdown table or compact bullets, "
    "never long paragraphs.\n"
    "- If the data does not contain the answer, say so plainly. Never "
    "fabricate numbers, dates, BL numbers, vessel names, or buyer names.\n"
    '- Prefer the "kpis", "originDues", and "risk" blocks for aggregate '
    'questions ("how many", "total", "split by"). Use the "rows" array for '
    "contract-specific questions.\n"
    '- If "matchedShipments" is far smaller than "totalShipments", state that '
    "you only see a filtered slice."
)


# ------------------------------------------------------------------ http handler
class handler(BaseHTTPRequestHandler):  # noqa: N801 - Vercel requires this name
    """Vercel's Python runtime invokes this class per request."""

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        body = self._read_json_body()
        if body is None:
            return self._json({"error": "Invalid JSON body"}, 400)

        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            return self._json(
                {"error": "OPENAI_API_KEY not configured on the server."}, 500
            )

        question = ""
        if isinstance(body, dict):
            question = (body.get("question") or "").strip()
        if not question:
            return self._json({"error": 'Missing "question"'}, 400)
        if len(question) > MAX_QUESTION_CHARS:
            return self._json(
                {"error": f"Question too long (>{MAX_QUESTION_CHARS} chars)."},
                413,
            )

        context = body.get("context") if isinstance(body, dict) else None
        if not isinstance(context, dict):
            context = {}

        try:
            context_json = json.dumps(
                context, separators=(",", ":"), ensure_ascii=False
            )
        except (TypeError, ValueError):
            return self._json({"error": "Context could not be serialised."}, 400)

        if len(context_json.encode("utf-8")) > MAX_CONTEXT_BYTES:
            return self._json(
                {
                    "error": (
                        f"Context too large (>{MAX_CONTEXT_BYTES}B). "
                        "Reduce rows in buildLlmContext()."
                    )
                },
                413,
            )

        model = os.environ.get("OPENAI_MODEL") or DEFAULT_MODEL

        upstream_payload = {
            "model": model,
            "temperature": 0.2,
            "max_tokens": 700,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "system",
                    "content": (
                        "JSON CONTEXT (the only data you may use):\n" + context_json
                    ),
                },
                {"role": "user", "content": question},
            ],
        }

        req = urllib.request.Request(
            OPENAI_URL,
            data=json.dumps(upstream_payload).encode("utf-8"),
            headers={
                "content-type": "application/json",
                "authorization": f"Bearer {api_key}",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=OPENAI_TIMEOUT_SEC) as resp:
                status = resp.status
                data = resp.read()
        except urllib.error.HTTPError as e:
            detail = self._safe_read(e)
            return self._json(
                {"error": f"OpenAI {e.code}", "detail": detail}, 502
            )
        except urllib.error.URLError as e:
            # Includes timeouts (socket.timeout wrapped in URLError on Python 3.10+)
            return self._json(
                {"error": "OpenAI request failed", "detail": str(e.reason)},
                504,
            )
        except Exception as e:  # noqa: BLE001 - last-resort guard
            return self._json(
                {"error": "Upstream request failed", "detail": str(e)}, 502
            )

        if status != 200:
            return self._json(
                {
                    "error": f"OpenAI {status}",
                    "detail": data.decode("utf-8", errors="replace")[:500],
                },
                502,
            )

        try:
            payload_out = json.loads(data.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return self._json(
                {"error": "OpenAI returned non-JSON response"}, 502
            )

        try:
            answer = payload_out["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError):
            answer = ""

        usage = (
            payload_out.get("usage") if isinstance(payload_out, dict) else None
        )

        return self._json({"answer": answer, "model": model, "usage": usage}, 200)

    def do_GET(self):  # noqa: N802
        return self._json({"error": "POST only"}, 405)

    def do_OPTIONS(self):  # noqa: N802 - CORS preflight (browsers on same origin won't send this, but be friendly)
        self.send_response(204)
        self.send_header("access-control-allow-methods", "POST, OPTIONS")
        self.send_header("access-control-allow-headers", "content-type")
        self.send_header("cache-control", "no-store")
        self.end_headers()

    # ------------------------------------------------------------------ helpers
    def _read_json_body(self):
        try:
            length = int(self.headers.get("content-length") or 0)
        except (TypeError, ValueError):
            length = 0
        raw = self.rfile.read(length) if length > 0 else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def _json(self, body, status=200):
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    @staticmethod
    def _safe_read(err) -> str:
        try:
            return err.read().decode("utf-8", errors="replace")[:500]
        except Exception:  # noqa: BLE001
            return ""

    # Silence default per-request access logs; Vercel already captures them.
    def log_message(self, format, *args):  # noqa: A002, N802
        return
