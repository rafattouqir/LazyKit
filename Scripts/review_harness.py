#!/usr/bin/env python3
"""Behavioural harness for the LazyKit AI reviewer.

Runs a stub CommandCode endpoint locally, points a throwaway copy of the reviewer
at it, and asserts on both the requests the reviewer made and the review it
wrote. Nothing here touches the real API or needs an API key.

Drives every implementation present in .github/scripts/ so they can be compared:

    python3 Scripts/review_harness.py            # all implementations found
    python3 Scripts/review_harness.py swift      # just one

The Python implementation is only exercised while ai_review.py still exists; the
cross-check against it is the cheapest proof that the Swift port is faithful, and
it stops being available the moment the Python is deleted.
"""

import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

IMPLEMENTATIONS = {
    "swift": {
        "path": os.path.join(REPO, ".github/scripts/ai_review.swift"),
        "runner": ["swift"],
        "patches": [
            (
                'let apiURL = "https://api.commandcode.ai/provider/v1/chat/completions"',
                'let apiURL = "http://127.0.0.1:{port}/v1/chat/completions"',
            ),
            (
                'let modelsURL = "https://api.commandcode.ai/provider/v1/models"',
                'let modelsURL = "http://127.0.0.1:{port}/v1/models"',
            ),
        ],
    },
    # ai_review.py is gone (ported to Swift and deleted). The entry stays so the
    # cross-check can be re-run if it is ever restored from git history:
    #   git show <sha>:.github/scripts/ai_review.py > .github/scripts/ai_review.py
    # Absent, it is skipped and the harness runs Swift alone.
    "python": {
        "path": os.path.join(REPO, ".github/scripts/ai_review.py"),
        "runner": ["python3"],
        "patches": [
            (
                'API_URL = "https://api.commandcode.ai/provider/v1/chat/completions"',
                'API_URL = "http://127.0.0.1:{port}/v1/chat/completions"',
            ),
            (
                'MODELS_URL = "https://api.commandcode.ai/provider/v1/models"',
                'MODELS_URL = "http://127.0.0.1:{port}/v1/models"',
            ),
        ],
    },
}

DIFF_TEXT = """diff --git a/Sources/LazyKit/Components/LazyButton.swift b/Sources/LazyKit/Components/LazyButton.swift
index 1111111..2222222 100644
--- a/Sources/LazyKit/Components/LazyButton.swift
+++ b/Sources/LazyKit/Components/LazyButton.swift
@@ -10,6 +10,8 @@ public struct LazyButton: View {
     public var body: some View {
+        let unused = 1
         Button(action: action) { Text(title) }
+            .disabled(isLoading)
     }
 }
"""

SKILL_NAMES = [
    "architecture",
    "lazykit-api",
    "repo-conventions",
    "swift-lint",
    "swift-testing",
    "swiftui",
]

PASSES, FAILS = [], []


def check(label, ok, detail=""):
    if ok:
        PASSES.append(label)
        print(f"    PASS  {label}")
    else:
        FAILS.append(label)
        print(f"    FAIL  {label}  {detail}")


def turn(content=None, calls=None, status=200):
    message = {"role": "assistant", "content": content}
    if calls is not None:
        message["tool_calls"] = calls
    return (
        status,
        {"choices": [{"message": message, "finish_reason": "tool_calls" if calls else "stop"}]},
    )


def call(name, call_id="call_1"):
    return {
        "id": call_id,
        "type": "function",
        "function": {"name": "load_skill", "arguments": json.dumps({"name": name})},
    }


REVIEW = json.dumps(
    {"summary": "looks fine", "risk": "low", "risk_reason": "no issues", "findings": []}
)

SCENARIOS = {
    "no_tool": [turn(REVIEW)],
    "one_tool": [turn(None, [call("swiftui")]), turn(REVIEW)],
    "two_tools": [
        turn(None, [call("swiftui", "c1")]),
        turn(None, [call("architecture", "c2")]),
        turn(REVIEW),
    ],
    "duplicate": [
        turn(None, [call("swiftui", "c1")]),
        turn(None, [call("swiftui", "c2")]),
        turn(REVIEW),
    ],
    "unknown_name": [
        turn(None, [call("swift-concurrency", "c1")]),
        turn(None, [call("swiftui", "c2")]),
        turn(REVIEW),
    ],
    "loop_cap": [turn(None, [call("swiftui", f"c{i}")]) for i in range(5)]
    + [turn(None, [call("swiftui", "clast")])],
    "answer_and_call": [
        (
            200,
            {
                "choices": [
                    {
                        "message": {
                            "role": "assistant",
                            "content": REVIEW,
                            "tool_calls": [call("swiftui")],
                        },
                        "finish_reason": "tool_calls",
                    }
                ]
            },
        )
    ],
    "tools_refused": [
        (400, {"error": {"code": "invalid_request", "message": "tools is not supported"}}),
        turn(REVIEW),
    ],
}

STUB = None


class Stub:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        STUB.requests.append(json.loads(self.rfile.read(length)))
        status, body = STUB.responses.pop(0) if STUB.responses else (200, {"choices": []})
        self._send(status, body)

    def do_GET(self):
        self._send(200, {"data": []})


def tool_replies(payload):
    return [m.get("content") or "" for m in payload["messages"] if m.get("role") == "tool"]


def run(impl_name, scenario, responses, port, workdir):
    """Run one implementation against the stub. Returns a result dict."""
    global STUB
    spec = IMPLEMENTATIONS[impl_name]
    STUB = Stub(responses)

    server = HTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with open(spec["path"], encoding="utf-8") as handle:
            source = handle.read()
        for old, new in spec["patches"]:
            replacement = new.format(port=port)
            if old not in source:
                raise AssertionError(f"{impl_name}: patch target not found: {old[:60]}")
            source = source.replace(old, replacement)

        extension = os.path.splitext(spec["path"])[1]
        script = os.path.join(workdir, f"patched_{impl_name}{extension}")
        with open(script, "w", encoding="utf-8") as handle:
            handle.write(source)

        out_path = os.path.join(workdir, f"review_{impl_name}.md")
        if os.path.exists(out_path):
            os.remove(out_path)

        # Hermetic: drop the ambient GitHub variables a CI runner sets by
        # default, so the harness behaves the same on a runner as it does
        # locally. --no-post already prevents any real API call; this makes that
        # invariant independent of where the harness runs.
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GITHUB_") and key != "GH_TOKEN"
        }
        env["COMMANDCODE_API_KEY"] = "test-key-not-real"
        proc = subprocess.run(
            spec["runner"]
            + [
                script,
                "--diff", os.path.join(workdir, "pr.diff"),
                "--pr-number", "0",
                "--repo", "local/test",
                "--no-post",
                "--output", out_path,
            ],
            capture_output=True,
            text=True,
            env=env,
            cwd=REPO,
            timeout=240,
        )
        review = ""
        if os.path.exists(out_path):
            with open(out_path, encoding="utf-8") as handle:
                review = handle.read()
        return {
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "requests": STUB.requests,
            "review": review,
        }
    finally:
        server.shutdown()
        server.server_close()


def check_no_tool(r):
    check("exit 0", r["returncode"] == 0, r["returncode"])
    check("exactly one request", len(r["requests"]) == 1, len(r["requests"]))
    check("tools offered on the first request", "tools" in r["requests"][0])
    check("response_format suppressed with tools", "response_format" not in r["requests"][0])
    enum = r["requests"][0]["tools"][0]["function"]["parameters"]["properties"]["name"]["enum"]
    check("enum lists all six skills", sorted(enum) == SKILL_NAMES, enum)
    system = r["requests"][0]["messages"][0]["content"]
    check(
        "system prompt carries the catalogue, not bodies",
        "Available review skills" in system and "=== SKILL:" not in system,
    )
    check("review written", "looks fine" in r["review"], r["review"][:120])
    check("footer reports no skills", "skills loaded: none" in r["review"], r["review"][-200:])


def check_one_tool(r):
    check("exit 0", r["returncode"] == 0, r["returncode"])
    check("two requests", len(r["requests"]) == 2, len(r["requests"]))
    check(
        "assistant tool turn echoed back",
        any(m.get("tool_calls") for m in r["requests"][1]["messages"]),
    )
    replies = tool_replies(r["requests"][1])
    check("one tool reply", len(replies) == 1, replies)
    check("tool reply carries the body", "=== SKILL: swiftui ===" in replies[0])
    tool_msgs = [m for m in r["requests"][1]["messages"] if m.get("role") == "tool"]
    check("tool_call_id preserved", tool_msgs[0]["tool_call_id"] == "call_1", tool_msgs[0])
    check("second request still carries tools", "tools" in r["requests"][1])
    check("footer reports swiftui", "skills loaded: swiftui" in r["review"], r["review"][-200:])


def check_two_tools(r):
    check("exit 0", r["returncode"] == 0, r["returncode"])
    check("three requests", len(r["requests"]) == 3, len(r["requests"]))
    # The assistant turn sits between the two tool replies, so scan every tool
    # reply rather than assuming they are adjacent.
    replies = tool_replies(r["requests"][2])
    check(
        "both bodies present by the third request",
        any("=== SKILL: swiftui ===" in x for x in replies)
        and any("=== SKILL: architecture ===" in x for x in replies),
        [x[:60] for x in replies],
    )
    check("footer reports both", "swiftui, architecture" in r["review"], r["review"][-200:])


def check_duplicate(r):
    check("exit 0", r["returncode"] == 0, r["returncode"])
    replies = tool_replies(r["requests"][2])
    check("second reply refuses politely", any("already loaded" in x for x in replies), replies)
    check(
        "body injected exactly once",
        sum("=== SKILL: swiftui ===" in x for x in replies) == 1,
        replies,
    )


def check_unknown_name(r):
    check("exit 0", r["returncode"] == 0, r["returncode"])
    first = tool_replies(r["requests"][1])[0]
    check("reply names the bogus skill", "swift-concurrency" in first, first[:100])
    check("reply lists the valid names", all(n in first for n in SKILL_NAMES), first[:220])
    # The retry's body is the last tool reply, not the first: request 3 carries
    # the error reply again before the successful one.
    replies = tool_replies(r["requests"][2])
    check(
        "retry succeeded",
        any("=== SKILL: swiftui ===" in x for x in replies),
        [x[:60] for x in replies],
    )


def check_loop_cap(r):
    check("exit 0, no crash", r["returncode"] == 0, r["returncode"])
    check("six requests: 5 tool turns + 1 forced", len(r["requests"]) == 6, len(r["requests"]))
    check("forced request dropped tools", "tools" not in r["requests"][5])
    check("warned about the cap", "forcing an answer" in r["stdout"], r["stdout"][-300:])
    check("honest summary in the review", "kept requesting" in r["review"], r["review"][:300])
    check("still wrote a valid review", "### Summary" in r["review"], r["review"][:200])


def check_answer_and_call(r):
    check("exit 0", r["returncode"] == 0, r["returncode"])
    check("no extra round trip", len(r["requests"]) == 1, len(r["requests"]))
    check("skill never loaded", "skills loaded: none" in r["review"], r["review"][-200:])


def check_tools_refused(r):
    check("exit 0", r["returncode"] == 0, r["returncode"])
    check("two requests: refused, then retry", len(r["requests"]) == 2, len(r["requests"]))
    check("first carried tools", "tools" in r["requests"][0])
    check("retry carried no tools", "tools" not in r["requests"][1])
    check(
        "warned about inlining",
        "inlining all 6 skill bodies" in r["stdout"],
        r["stdout"][-400:],
    )
    inlined = r["requests"][1]["messages"][0]["content"]
    missing = [n for n in SKILL_NAMES if f"=== SKILL: {n} ===" not in inlined]
    check("every body inlined", not missing, f"missing={missing}")
    check("catalogue replaced by bodies", "Available review skills" not in inlined)


CHECKS = {
    "no_tool": check_no_tool,
    "one_tool": check_one_tool,
    "two_tools": check_two_tools,
    "duplicate": check_duplicate,
    "unknown_name": check_unknown_name,
    "loop_cap": check_loop_cap,
    "answer_and_call": check_answer_and_call,
    "tools_refused": check_tools_refused,
}


def normalise_known_divergences(text):
    """Absorb divergences where the port deliberately fixes the original.

    The Python `loop_cap` fallback interpolated `loaded` (a list) straight into an
    f-string, so the review comment read "Skills loaded: ['swiftui']" — a Python
    repr leaking into user-visible output. The port prints "swiftui". That is the
    only allowed difference, and it is a fix, not a regression.
    """
    return re.sub(
        r"Skills loaded: \[(.*?)\]",
        lambda m: "Skills loaded: "
        + ", ".join(part.strip().strip("'\"") for part in m.group(1).split(",")),
        text,
    )


def main():
    requested = sys.argv[1:] or list(IMPLEMENTATIONS)
    available = [n for n in requested if os.path.exists(IMPLEMENTATIONS[n]["path"])]
    for name in requested:
        if name not in available:
            print(f"skipping {name}: {IMPLEMENTATIONS[name]['path']} not found")

    if not available:
        print("nothing to run")
        return 1

    workdir = tempfile.mkdtemp(prefix="lazykit_review_")
    with open(os.path.join(workdir, "pr.diff"), "w", encoding="utf-8") as handle:
        handle.write(DIFF_TEXT)

    outputs = {}
    try:
        port = 8800
        for name in available:
            print()
            print("=" * 72)
            print(f"IMPLEMENTATION: {name}")
            print("=" * 72)
            outputs[name] = {}
            for scenario, responses in SCENARIOS.items():
                print()
                print(f"  -- {scenario} --")
                try:
                    result = run(name, scenario, responses, port, workdir)
                except Exception as exc:  # noqa: BLE001 - harness reports, never crashes
                    check(f"{scenario}: ran", False, repr(exc))
                    port += 1
                    continue
                port += 1
                try:
                    CHECKS[scenario](result)
                except Exception as exc:  # noqa: BLE001 - a broken check must not kill the run
                    check(f"{scenario}: checks completed", False, repr(exc))
                outputs[name][scenario] = result["review"]
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if len(available) > 1:
        print()
        print("=" * 72)
        print("CROSS-CHECK: review output per scenario")
        print("=" * 72)
        first, *rest = available
        for scenario in SCENARIOS:
            if scenario not in outputs[first]:
                continue
            baseline = outputs[first][scenario]
            for other in rest:
                if scenario not in outputs[other]:
                    continue
                candidate = outputs[other][scenario]
                if baseline == candidate:
                    check(f"{scenario}: {first} == {other}", True)
                elif normalise_known_divergences(baseline) == normalise_known_divergences(
                    candidate
                ):
                    check(
                        f"{scenario}: {first} == {other} "
                        f"(modulo the Python list-repr fix)",
                        True,
                    )
                else:
                    detail = "\n".join(
                        difflib.unified_diff(
                            baseline.splitlines(),
                            candidate.splitlines(),
                            fromfile=first,
                            tofile=other,
                            lineterm="",
                        )
                    )
                    check(f"{scenario}: {first} == {other}", False, "\n" + detail)

    print()
    print("=" * 72)
    print(f"RESULT: {len(PASSES)} passed, {len(FAILS)} failed")
    if FAILS:
        for name in FAILS:
            print(f"  - {name}")
        return 1
    print("All scenarios green.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
