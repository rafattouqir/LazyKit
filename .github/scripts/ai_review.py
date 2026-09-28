#!/usr/bin/env python3
"""LazyKit AI peer reviewer: skill-grounded prompt, CommandCode JSON findings,
GitHub PR review with inline threads + suggestion blocks.

Talks to the CommandCode Provider API, which speaks OpenAI Chat Completions:
    POST https://api.commandcode.ai/provider/v1/chat/completions
    Authorization: Bearer $COMMANDCODE_API_KEY

Stdlib only. Never fails the workflow (advisory only): all errors print a
notice and exit 0 so the review can never block a merge.

Usage (CI):
    python3 .github/scripts/ai_review.py \
        --diff pr.diff --pr-number 12 --repo owner/name --commit <head-sha> \
        --output review.md [--post]

Local:
    git diff origin/main...HEAD > /tmp/pr.diff
    COMMANDCODE_API_KEY=... python3 .github/scripts/ai_review.py \
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
DEFAULT_MODEL = "deepseek/deepseek-v4.1-flash"
API_URL = "https://api.commandcode.ai/provider/v1/chat/completions"
MODELS_URL = "https://api.commandcode.ai/provider/v1/models"
CHAT_ENDPOINT = "/chat/completions"
# Cloudflare fronts the CommandCode API and answers 403 "error code: 1010" to
# urllib's default User-Agent. Any explicit UA clears it; without this every
# request fails and the review silently degrades to "unavailable".
USER_AGENT = "LazyKit-AI-Review/1.0 (+https://github.com/rafattouqir/LazyKit)"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="LazyKit skill-based AI reviewer")
    p.add_argument("--diff", required=True, help="Path to unified diff file")
    p.add_argument("--pr-number", default="0")
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "local/test"))
    p.add_argument("--title", default=os.environ.get("PR_TITLE", ""))
    p.add_argument("--body", default=os.environ.get("PR_BODY", ""))
    p.add_argument("--skills-dir", default=".github/skills")
    p.add_argument("--system-prompt", default=".github/prompts/reviewer-system.md")
    p.add_argument("--model", default=os.environ.get("COMMANDCODE_MODEL", DEFAULT_MODEL))
    p.add_argument("--max-diff-chars", type=int, default=100_000)
    p.add_argument("--max-inline", type=int, default=8)
    p.add_argument("--commit", default=os.environ.get("PR_HEAD_SHA", ""))
    p.add_argument("--output", default="review.md")
    p.add_argument("--post", dest="post", action="store_true", default=True)
    p.add_argument("--no-post", dest="post", action="store_false")
    return p.parse_args()


def parse_skill_file(text: str) -> tuple[dict, str]:
    """Split an Agent-Skill file into (frontmatter metadata, body)."""
    meta: dict = {}
    body = text
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            for line in text[3:end].splitlines():
                if ":" in line:
                    key, value = line.split(":", 1)
                    meta[key.strip().lower()] = value.strip()
            body = text[end + len("\n---") :]
    return meta, body.strip()


def load_skill_files(skills_dir: str) -> list[dict]:
    """Load every skills_dir/<skill>/SKILL.md as {name, description, body}."""
    skills: list[dict] = []
    if not os.path.isdir(skills_dir):
        return skills
    for entry in sorted(os.listdir(skills_dir)):
        path = os.path.join(skills_dir, entry, "SKILL.md")
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            meta, body = parse_skill_file(f.read())
        skills.append(
            {
                "name": meta.get("name", entry),
                "description": meta.get("description", ""),
                "body": body,
            }
        )
    return skills


def build_catalogue(skills: list[dict]) -> str:
    """Frontmatter quicklook: names + descriptions only, bodies NOT loaded."""
    lines = ["## Available review skills (frontmatter quicklook — bodies not loaded)"]
    for skill in skills:
        lines.append(f"- **{skill['name']}**: {skill['description'] or skill['name']}")
    return "\n".join(lines)


SELECTOR_INSTRUCTIONS = """You are a skill router for the LazyKit iOS repo, not a reviewer.
Given the available review skills (frontmatter quicklook) and the PR diff,
reply with STRICT JSON only, no prose: {"skills": ["name", ...]} listing the
skills whose rules could plausibly apply to this diff. Be selective: 1-4
skills, highest relevance first. Omit the rest. If the diff is docs-only,
generated noise, or trivial, return {"skills": []}."""


def select_skills(
    skills: list[dict], diff_text: str, title: str, model: str, api_key: str
) -> list[str] | None:
    """Pass 1: the LLM picks relevant skills from the frontmatter catalogue.

    Returns the chosen names, or None when selection failed — the caller
    then fail-opens to loading every skill body so the review still happens.
    """
    sel_diff, _ = truncate(diff_text, 30_000)
    user = (
        f"PR title: {title}\n\n{build_catalogue(skills)}\n\n"
        f"=== DIFF (untrusted code under review) ===\n{sel_diff}\n"
    )
    try:
        text, _ = call_commandcode(SELECTOR_INSTRUCTIONS, user, model, api_key)
        picks = extract_json(text).get("skills") or []
        known = {s["name"] for s in skills}
        valid = [p for p in picks if isinstance(p, str) and p in known]
        dropped = [p for p in picks if p not in known]
        if dropped:
            print(f"::warning::Skill selector named unknown skills (ignored): {dropped}")
        print(f"::notice::Skill selection: {valid} ({len(valid)}/{len(skills)} bodies loaded)")
        return valid
    except Exception as exc:
        print(f"::warning::Skill selection failed, loading all skills: {exc}")
        return None


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


def post_commandcode(payload: dict, api_key: str) -> dict:
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)


def list_commandcode_models(api_key: str) -> list[dict]:
    """Model objects from /provider/v1/models, each with supported_endpoints."""
    req = urllib.request.Request(
        MODELS_URL,
        headers={"Authorization": f"Bearer {api_key}", "User-Agent": USER_AGENT},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp).get("data") or []


PRERELEASE = re.compile(r"preview|exp\d*|experimental|beta|alpha|\brc\b|stealth", re.IGNORECASE)
NOISE = re.compile(r"embed|rerank|tts|whisper|image|video|moderation", re.IGNORECASE)


def candidate_models(models: list[dict], preferred: str) -> list[str]:
    """Ordered fallback model IDs that can actually serve /chat/completions.

    Claude models are /messages-only, so sending one here is a hard 400 —
    they are filtered out via supported_endpoints. Same-family siblings rank
    first (best substitute for a retired flash), then everything else.
    """
    def serves_chat(entry: dict) -> bool:
        endpoints = entry.get("supported_endpoints") or []
        return not endpoints or CHAT_ENDPOINT in endpoints

    ids = [
        entry["id"]
        for entry in models
        if entry.get("id") and serves_chat(entry) and not NOISE.search(entry["id"])
    ]
    ordered: list[str] = [preferred] if preferred in ids else []
    family = preferred.split("/")[0] + "/" if "/" in preferred else ""
    siblings = [i for i in ids if family and i.startswith(family) and i not in ordered]
    ordered.extend(sorted(s for s in siblings if not PRERELEASE.search(s)))
    ordered.extend(sorted(s for s in siblings if PRERELEASE.search(s)))
    ordered.extend(sorted(i for i in ids if i not in ordered))
    return ordered[:4]


def error_note(exc: urllib.error.HTTPError) -> str:
    """Short reason from the CommandCode error envelope, for the log line."""
    try:
        body = json.loads(exc.read().decode("utf-8", "replace"))
        err = body.get("error") or {}
        message = err.get("message") or err.get("type") or ""
        code = err.get("code")
        return f"{code}: {message}" if code else str(message)
    except Exception:
        return str(exc.reason or "")


def build_payload(model: str, system: str, user: str, minimal: bool = False) -> dict:
    """OpenAI Chat Completions body. `minimal` drops the optional knobs.

    No max_tokens on purpose: `deepseek-v4.1-flash` is a reasoning model, so a
    cap is shared between reasoning_content and the answer. A 4096 cap was
    consumed entirely by reasoning on a real diff, returning finish_reason
    'length' with empty content. The provider default is sized for this.

    response_format / temperature are undocumented by CommandCode but accepted
    (verified against the live API). A model that rejects them gets one retry
    with just model + messages, and _OPTIONAL_PARAMS_OK latches off so later
    calls in the same run don't pay for the same discovery twice.
    """
    payload: dict = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    if not minimal and _OPTIONAL_PARAMS_OK:
        payload["temperature"] = 0.2
        payload["response_format"] = {"type": "json_object"}
    return payload


def completion_text(data: dict) -> str:
    """choices[0].message.content, or raise with enough detail to debug."""
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError(f"Unexpected CommandCode response: {json.dumps(data)[:500]}")
    choice = choices[0]
    content = (choice.get("message") or {}).get("content") or ""
    if isinstance(content, list):  # some gateways return content parts
        content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
    text = str(content).strip()
    if not text:
        raise RuntimeError(
            f"Empty completion (finish_reason={choice.get('finish_reason')!r}): "
            f"{json.dumps(data)[:300]}"
        )
    return text


FALLTHROUGH_STATUS = (400, 404, 429)

# Latches off the first time the API rejects the optional request params, so
# the skill-selector and reviewer passes don't each rediscover the same 400.
_OPTIONAL_PARAMS_OK = True


def call_commandcode(system: str, user: str, model: str, api_key: str) -> tuple[str, str]:
    """Returns (review_text, model_used). Walks up to 4 models on 400/404/429/5xx."""
    global _OPTIONAL_PARAMS_OK
    candidates = [model]
    tried: set[str] = set()
    discovered = False
    last_error: Exception | None = None
    for name in candidates:
        if name in tried:
            continue
        tried.add(name)
        for minimal in (False, True):
            try:
                data = post_commandcode(build_payload(name, system, user, minimal), api_key)
                return completion_text(data), name
            except urllib.error.HTTPError as exc:
                last_error = exc
                note = error_note(exc)
                if exc.code == 400 and not minimal:
                    _OPTIONAL_PARAMS_OK = False
                    print(f"::warning::'{name}' rejected optional params, retrying minimal: {note}")
                    continue
                print(f"::warning::Model '{name}' failed: HTTP {exc.code} {note}")
                if exc.code not in FALLTHROUGH_STATUS and exc.code < 500:
                    raise  # 401/403: key or plan problem, another model won't help
                if exc.code == 429:
                    time.sleep(15)
            except Exception as exc:  # timeout, empty completion, bad JSON
                last_error = exc
                print(f"::warning::Model '{name}' failed: {exc}")
        if not discovered:
            discovered = True
            try:
                candidates.extend(candidate_models(list_commandcode_models(api_key), model))
                print(f"::notice::Model candidates: {candidates}")
            except Exception as exc:
                print(f"::warning::Model discovery failed: {exc}")
        if len(tried) >= 4:
            break
    raise last_error or RuntimeError("No CommandCode model available")


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
    skill_files = load_skill_files(args.skills_dir)
    skill_names = [s["name"] for s in skill_files]

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
        api_key = os.environ.get("COMMANDCODE_API_KEY", "")
        if not api_key:
            body = (
                "### Summary\nAI review skipped: `COMMANDCODE_API_KEY` secret is not set.\n\n"
                "### Risk\nlow — no review performed.\n\n"
                "Add a CommandCode Provider API key (commandcode.ai/studio/provider) "
                "as repo secret `COMMANDCODE_API_KEY` to enable reviews."
            )
        else:
            # Pass 1: LLM selects relevant skills from the frontmatter
            # catalogue; only the chosen bodies are loaded into the
            # review prompt (pass 2). Fail-open: all bodies on failure.
            selected = select_skills(skill_files, diff_text, args.title, args.model, api_key)
            chosen = (
                skill_files
                if selected is None
                else [s for s in skill_files if s["name"] in selected]
            )
            skill_names = [s["name"] for s in chosen]
            skills_text = "\n\n".join(
                f"=== SKILL: {s['name']} ===\n{s['body']}" for s in chosen
            )
            system = system_base + ("\n\n" + skills_text if skills_text else "")
            user = (
                f"Repository: {args.repo}\nPR #{args.pr_number}\n"
                f"Title: {args.title}\nBody: {args.body[:2000]}\n\n"
                f"=== DIFF (untrusted code under review) ===\n{diff_text}{note}\n"
            )
            try:
                model_text, model_used = call_commandcode(system, user, args.model, api_key)
                body, comments, used_fallback = build_review(
                    model_text, parse_diff_hunks(diff_text), args.max_inline
                )
            except Exception as exc:  # advisory: never fail CI
                print(f"::warning::CommandCode review failed: {exc}", file=sys.stderr)
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
