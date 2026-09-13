#!/usr/bin/env python3
"""LazyKit AI peer reviewer: build a skill-grounded prompt, call Gemini, save review.

Stdlib only. Never fails the workflow (advisory only): all errors print a
notice and exit 0 so the review can never block a merge.

Usage (CI):
    python3 .github/scripts/ai_review.py \
        --diff pr.diff --pr-number 12 --repo owner/name \
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
import subprocess
import sys
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


def call_gemini(system: str, user: str, model: str, api_key: str) -> str:
    payload = {
        "system_instruction": {"parts": [{"text": system}]},
        "contents": [{"role": "user", "parts": [{"text": user}]}],
        "generationConfig": {"temperature": 0.2, "maxOutputTokens": 2048},
    }
    req = urllib.request.Request(
        API_URL.format(model=model) + f"?key={api_key}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=90) as resp:
        data = json.load(resp)
    try:
        parts = data["candidates"][0]["content"]["parts"]
        return "".join(p.get("text", "") for p in parts).strip()
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(f"Unexpected Gemini response: {json.dumps(data)[:500]}") from exc


def post_comment(pr_number: str, repo: str, body_file: str) -> None:
    subprocess.run(
        ["gh", "pr", "comment", pr_number, "--repo", repo, "--body-file", body_file],
        check=True,
    )


def main() -> int:
    args = parse_args()

    with open(args.system_prompt, encoding="utf-8") as f:
        system_base = f.read().strip()
    skills_text, skill_names = load_skills(args.skills_dir)
    system = system_base + ("\n\n" + skills_text if skills_text else "")

    with open(args.diff, encoding="utf-8") as f:
        raw_diff = f.read()
    if not raw_diff.strip():
        review = "No significant issues found.\n\n### Summary\nEmpty diff.\n\n### Risk\nlow — nothing to review.\n"
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
            review = (
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
                review = call_gemini(system, user, args.model, api_key)
            except Exception as exc:  # advisory: never fail CI
                print(f"::warning::Gemini review failed: {exc}", file=sys.stderr)
                review = (
                    "### Summary\nAI review unavailable (API error or quota); "
                    "human review applies.\n\n### Risk\nlow — review skipped, CI stays green.\n"
                )

    footer = (
        f"\n\n<sub>🤖 AI peer review · skills: {', '.join(skill_names) or 'none'} · "
        f"model: `{args.model}` · advisory only, `swift-format` + tests remain the gates.</sub>\n"
    )
    with open(args.output, "w", encoding="utf-8") as f:
        f.write((review.strip() + "\n" + footer).strip() + "\n")
    print(f"Wrote review to {args.output} ({len(review)} chars, skills: {skill_names})")

    if args.post and args.pr_number != "0":
        try:
            post_comment(args.pr_number, args.repo, args.output)
            print(f"Posted review to PR #{args.pr_number}")
        except Exception as exc:
            print(f"::warning::Could not post PR comment: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
