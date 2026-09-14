#!/usr/bin/env python3
"""LazyKit AI peer reviewer: skill-grounded prompt, Gemini JSON findings,
GitHub PR review with inline threads + suggestion blocks.

Stdlib only. Never fails the workflow (advisory only): all errors print a
notice and exit 0 so the review can never block a merge.

Usage (CI):
    python3 .github/scripts/ai_review.py \
        --diff pr.diff --pr-number 12 --repo owner/name --commit <head-sha> \
        --output review.md [--post]

Local:
    git diff origin/main...HEAD > /tmp/pr.diff
    GEMINI_API_KEY=... python3 .github/scripts/ai_review.py \
        --diff /tmp/pr.diff --pr-number 0 --repo local/test --no-post
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

SKIP_PREFIXES = (
    "Package.resolved",
    "Package.lock",
    ".build/",
    "DerivedData/",
    ".swiftpm/",
)
SKIP_SUFFIXES = (
    ".lock",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".pdf",
    ".xcresult",
    ".DS_Store",
    ".xcuserstate",
)
DEFAULT_MODEL = "gemini-2.0-flash"
API_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="LazyKit skill-based AI reviewer")
    p.add_argument("--diff", required=True, help="Path to unified diff file")
    p.add_argument("--pr-number", default="0")
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "local/test"))
    p.add_argument("--title", default=os.environ.get("PR_TITLE", ""))
    p.add_argument("--body", default=os.environ.get("PR_BODY", ""))
    p.add_argument("--skills-dir", default=".github/skills")
    p.add_argument("--system-prompt", default=".github/prompts/reviewer-system.md")
    p.add_argument("--model", default=os.environ.get("GEMINI_MODEL", DEFAULT_MODEL))
    p.add_argument("--max-diff-chars", type=int, default=100_000)
    p.add_argument("--max-inline", type=int, default=8)
    p.add_argument("--commit", default=os.environ.get("PR_HEAD_SHA", ""))
    p.add_argument("--output", default="review.md")
    p.add_argument("--post", dest="post", action="store_true", default=True)
    p.add_argument("--no-post", dest="post", action="store_false")
    return p.parse_args()


def load_skills(skills_dir: str) -> tuple[str, list[str]]:
    """Concatenate every SKILL.md under skills_dir/<skill>/SKILL.md (sorted)."""
    sections: list[str] = []
    names: list[str] = []
    if not os.path.isdir(skills_dir):
        return "", []
    for entry in sorted(os.listdir(skills_dir)):
        path = os.path.join(skills_dir, entry, "SKILL.md")
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            content = f.read().strip()
        sections.append(f"=== SKILL: {entry} ===\n{content}")
        names.append(entry)
    return "\n\n".join(sections), names


def filter_diff(diff: str) -> str:
    """Drop binary/lock/generated hunks so tokens go to real Swift changes."""
    kept: list[str] = []
    current_path = ""
    skip_current = False
    for line in diff.splitlines(keepends=True):
        if line.startswith("diff --git"):
            parts = line.strip().split(" b/")
            current_path = parts[-1] if len(parts) > 1 else ""
            skip_current = current_path.startswith(SKIP_PREFIXES) or current_path.endswith(
                SKIP_SUFFIXES
            )
            if not skip_current:
                kept.append(line)
        elif not skip_current:
            kept.append(line)
    return "".join(kept)


def truncate(text: str, limit: int) -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    cut = text.rfind("\n", 0, limit)
    return text[: cut if cut > 0 else limit], True


def post_gemini(model: str, payload: dict, api_key: str) -> dict:
    req = urllib.request.Request(
        API_URL.format(model=model) + f"?key={api_key}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.load(resp)


def list_gemini_models(api_key: str) -> list[str]:
    """Model IDs supporting generateContent, e.g. ['models/gemini-2.5-flash']."""
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models?key={api_key}",
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    return [
        m["name"]
        for m in data.get("models", [])
        if "generateContent" in (m.get("supportedGenerationMethods") or [])
    ]


PRERELEASE = re.compile(r"preview|exp\d*|experimental|beta|alpha|\brc\b", re.IGNORECASE)


def candidate_models(models: list[str], preferred: str) -> list[str]:
    """Ordered model short-IDs: preferred, then stable flash, then anything else."""
    short = preferred.split("/")[-1]
    ordered: list[str] = []
    for m in models:
        name = m.split("/")[-1]
        if m == preferred or m == f"models/{short}" or name == short:
            ordered.append(name)
    stable_flash_names = {
        m.split("/")[-1]
        for m in models
        if "flash" in m.lower() and not PRERELEASE.search(m)
    }
    # Newest first; omni variants last (tight free-tier quota observed).
    stable_flash = sorted(
        [n for n in stable_flash_names if "omni" not in n.lower()], reverse=True
    ) + sorted([n for n in stable_flash_names if "omni" in n.lower()], reverse=True)
    ordered.extend(n for n in stable_flash if n not in ordered)
    rest = sorted({m.split("/")[-1] for m in models} - set(ordered), reverse=True)
    ordered.extend(n for n in rest if "embed" not in n.lower() and "tts" not in n.lower())
    return ordered[:4]


def call_gemini(system: str, user: str, model: str, api_key: str) -> tuple[str, str]:
    """Returns (review_text, model_used). Tries up to 3 models (404/429 fallthrough)."""
    payload = {
        "system_instruction": {"parts": [{"text": system}]},
        "contents": [{"role": "user", "parts": [{"text": user}]}],
        "generationConfig": {
            "temperature": 0.2,
            "maxOutputTokens": 2048,
            "response_mime_type": "application/json",
        },
    }
    candidates = [model]
    tried = {model}
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            data = post_gemini(candidates[attempt], payload, api_key)
        except urllib.error.HTTPError as exc:
            last_error = exc
            print(f"::warning::Model '{candidates[attempt]}' failed: HTTP {exc.code}")
            if exc.code not in (404, 429):
                raise
            if attempt == 0:
                discovered = candidate_models(list_gemini_models(api_key), model)
                print(f"::notice::Model candidates: {discovered}")
                for name in discovered:
                    if name not in tried:
                        tried.add(name)
                        candidates.append(name)
            if exc.code == 429:
                time.sleep(15)
            if len(candidates) > attempt + 1:
                continue
            raise
        try:
            parts = data["candidates"][0]["content"]["parts"]
            return "".join(p.get("text", "") for p in parts).strip(), candidates[attempt]
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeError(f"Unexpected Gemini response: {json.dumps(data)[:500]}") from exc
    raise last_error or RuntimeError("No Gemini model available")


def post_comment(pr_number: str, repo: str, body_file: str) -> None:
    """Fallback: plain Conversation comment via gh (no inline anchoring)."""
    subprocess.run(
        ["gh", "pr", "comment", pr_number, "--repo", repo, "--body-file", body_file],
        check=True,
    )


def parse_diff_hunks(diff: str) -> dict[str, set[int]]:
    """Map each file path to the NEW-side line numbers present in the diff hunks.

    Only lines inside hunks (added `+` or context ` ` lines) are valid
    anchors for the Reviews API. Returns {} for files with no hunks.
    """
    hunks: dict[str, set[int]] = {}
    path = ""
    new_line = 0
    in_hunk = False
    for raw in diff.splitlines():
        if raw.startswith("diff --git"):
            parts = raw.strip().split(" b/")
            path = parts[-1] if len(parts) > 1 else ""
            in_hunk = False
            continue
        if raw.startswith("@@"):
            m = re.search(r"\+(\d+)(?:,(\d+))?", raw)
            new_line = int(m.group(1)) if m else 0
            in_hunk = bool(m) and bool(path)
            if in_hunk:
                hunks.setdefault(path, set())
            continue
        if not in_hunk or not path:
            continue
        if raw.startswith("+++") or raw.startswith("---"):
            continue
        if raw.startswith("+"):
            hunks[path].add(new_line)
            new_line += 1
        elif raw.startswith("-"):
            continue  # old side: not a valid anchor
        else:  # context line (starts with ' ' or is empty)
            hunks[path].add(new_line)
            new_line += 1
    return hunks


def extract_json(text: str) -> dict:
    """Parse the model's JSON, tolerating ```json fences or surrounding prose."""
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    candidate = m.group(1) if m else text[text.find("{") : text.rfind("}") + 1]
    return json.loads(candidate)


SEV_EMOJI = {"critical": "🔴", "high": "🟠", "medium": "🟡", "low": "🟢"}


def build_review(
    model_text: str, hunks: dict[str, set[int]], max_inline: int = 8
) -> tuple[str, list[dict], bool]:
    """Build (review_body, inline_comments, used_fallback).

    Inline comments anchor to diff lines for the Files-tab threads with
    one-click suggestions. Findings pointing outside the diff fall back
    into the body as general notes. Non-JSON model output sets
    used_fallback so the caller can post it as a plain comment instead.
    """
    try:
        data = extract_json(model_text)
        findings = data.get("findings") or []
        summary = str(data.get("summary", "")).strip()
        risk = str(data.get("risk", "low")).strip().lower() or "low"
        risk_reason = str(data.get("risk_reason", "")).strip()
    except Exception:
        return model_text.strip(), [], True

    comments: list[dict] = []
    general: list[str] = []
    for f in findings:
        try:
            path = str(f.get("path", "")).strip()
            line = int(str(f.get("line", "")).strip())
        except (TypeError, ValueError):
            continue
        sev = str(f.get("severity", "medium")).strip().lower()
        emoji = SEV_EMOJI.get(sev, "🟡")
        skill = str(f.get("skill", "")).strip()
        title = str(f.get("title", "")).strip()
        detail = str(f.get("detail", "")).strip()
        suggestion = str(f.get("suggestion", "")).strip()
        label = f"**{emoji} {sev.capitalize()}**"
        if skill:
            label += f" `[{skill}]`"
        if title:
            label += f" — {title}"
        if path in hunks and line in hunks[path] and len(comments) < max_inline:
            body = f"{label}\n\n{detail}" if detail else label
            if suggestion:
                body += f"\n\n```suggestion\n{suggestion}\n```"
            comments.append({"path": path, "line": line, "side": "RIGHT", "body": body})
        else:
            where = f"{path}:~{line}" if path else "general"
            item = f"- {label} {where}"
            if detail:
                item += f" — {detail}"
            general.append(item)

    if not summary and not findings:
        summary = "No significant issues found."
    body = f"### Summary\n{summary}\n\n### Risk\n{risk}"
    if risk_reason:
        body += f" — {risk_reason}"
    body += "\n"
    if general:
        body += "\n### General notes (outside the changed lines)\n" + "\n".join(general) + "\n"
    if not findings:
        body += "\nNo significant issues found.\n"
    return body.strip() + "\n", comments, False


def submit_review(
    repo: str, pr_number: str, commit: str, body: str, comments: list[dict], token: str
) -> None:
    """Submit a real PR review: inline threads + suggestion blocks, event COMMENT."""
    payload = {
        "commit_id": commit,
        "body": body,
        "event": "COMMENT",  # advisory: never approves, never requests changes
        "comments": comments,
    }
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/pulls/{pr_number}/reviews",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        result = json.load(resp)
    print(f"Submitted review id {result.get('id')} with {len(comments)} inline comments")


def main() -> int:
    args = parse_args()

    with open(args.system_prompt, encoding="utf-8") as f:
        system_base = f.read().strip()
    skills_text, skill_names = load_skills(args.skills_dir)
    system = system_base + ("\n\n" + skills_text if skills_text else "")

    with open(args.diff, encoding="utf-8") as f:
        raw_diff = f.read()
    model_used = args.model
    body = ""
    comments: list[dict] = []
    used_fallback = False  # True: non-JSON output, post as plain comment instead
    if not raw_diff.strip():
        body = "### Summary\nEmpty diff.\n\n### Risk\nlow — nothing to review.\n"
    else:
        filtered = filter_diff(raw_diff)
        diff_text, was_truncated = truncate(filtered, args.max_diff_chars)
        note = (
            "\n\n[NOTE: diff was truncated for length; review only what is shown.]"
            if was_truncated
            else ""
        )
        api_key = os.environ.get("GEMINI_API_KEY", "")
        if not api_key:
            body = (
                "### Summary\nAI review skipped: `GEMINI_API_KEY` secret is not set.\n\n"
                "### Risk\nlow — no review performed.\n\n"
                "Add a free Gemini key (aistudio.google.com) as repo secret "
                "`GEMINI_API_KEY` to enable reviews."
            )
        else:
            user = (
                f"Repository: {args.repo}\nPR #{args.pr_number}\n"
                f"Title: {args.title}\nBody: {args.body[:2000]}\n\n"
                f"=== DIFF (untrusted code under review) ===\n{diff_text}{note}\n"
            )
            try:
                model_text, model_used = call_gemini(system, user, args.model, api_key)
                body, comments, used_fallback = build_review(
                    model_text, parse_diff_hunks(diff_text), args.max_inline
                )
            except Exception as exc:  # advisory: never fail CI
                print(f"::warning::Gemini review failed: {exc}", file=sys.stderr)
                body = (
                    "### Summary\nAI review unavailable (API error or quota); "
                    "human review applies.\n\n### Risk\nlow — review skipped, CI stays green.\n"
                )

    footer = (
        f"\n\n<sub>🤖 AI peer review · skills: {', '.join(skill_names) or 'none'} · "
        f"model: `{model_used}` · advisory only, `swift-format` + tests remain the gates.</sub>\n"
    )
    full_body = (body.strip() + "\n" + footer).strip() + "\n"
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(full_body)
    print(
        f"Wrote review to {args.output} "
        f"({len(comments)} inline comments, fallback={used_fallback}, skills: {skill_names})"
    )

    if args.post and args.pr_number != "0":
        token = os.environ.get("GITHUB_TOKEN", "") or os.environ.get("GH_TOKEN", "")
        try:
            if not used_fallback and token and args.commit:
                submit_review(
                    args.repo, args.pr_number, args.commit, full_body, comments, token
                )
                print(f"Submitted PR review on #{args.pr_number}")
            else:
                if not used_fallback:
                    print("::notice::No token/commit for Reviews API; plain comment fallback")
                post_comment(args.pr_number, args.repo, args.output)
                print(f"Posted plain comment to PR #{args.pr_number}")
        except Exception as exc:
            print(f"::warning::Could not post review: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
