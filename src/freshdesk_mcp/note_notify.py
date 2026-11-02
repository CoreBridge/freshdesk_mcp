"""Resolve Freshdesk note agent tags to real notify_emails (FD-414725).

Visual @-tags (/a/agents/{id}) do not email anyone unless the Notes API
receives notify_emails. create_ticket_note must auto-fill from the staff
directory and refuse to post when a tag cannot be notified.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence

AGENT_HREF_RE = re.compile(
    r"(?:https?://[^\"'>\s]+)?/a/agents/(\d+)", re.IGNORECASE
)
FRESHDESK_PROTO_RE = re.compile(r"freshdesk://agents/(\d+)", re.IGNORECASE)
PERSON_SPLIT_RE = re.compile(r"\n {2}- id:")
AGENT_ID_RE = re.compile(r'freshdesk_agent_id:\s*"?(\d+)"?')
NOTIFY_BLOCK_RE = re.compile(r"notify_emails:\s*\n((?:[ \t]+-[ \t]+.+\n?)*)")
NOTIFY_EMAIL_RE = re.compile(r"^[ \t]+-[ \t]+(\S+@\S+)", re.MULTILINE)
EMAIL_FIELD_RE = re.compile(r"^\s+email:\s*(\S+@\S+)", re.MULTILINE)


def staff_directory_path() -> Path:
    home = os.environ.get("USERPROFILE") or os.environ.get("HOME") or ""
    return (
        Path(home)
        / ".cursor"
        / "skills"
        / "corebridge-staff-directory"
        / "directory.yaml"
    )


def unique_emails(emails: Optional[Iterable[str]]) -> List[str]:
    out: List[str] = []
    seen = set()
    for raw in emails or []:
        e = str(raw or "").strip().lower()
        if not e or "@" not in e or e in seen:
            continue
        seen.add(e)
        out.append(e)
    return out


def load_staff_notify_map(directory: Optional[Path] = None) -> Dict[str, List[str]]:
    path = directory or staff_directory_path()
    mapping: Dict[str, List[str]] = {}
    if not path.is_file():
        return mapping
    text = path.read_text(encoding="utf-8")
    blocks = PERSON_SPLIT_RE.split(text)
    for block in blocks[1:]:
        id_match = AGENT_ID_RE.search(block)
        if not id_match:
            continue
        agent_id = id_match.group(1)
        emails: List[str] = []
        notify_block = NOTIFY_BLOCK_RE.search(block)
        if notify_block:
            for m in NOTIFY_EMAIL_RE.finditer(notify_block.group(1)):
                emails.append(m.group(1).strip().strip("\"'"))
        if not emails:
            em = EMAIL_FIELD_RE.search(block)
            if em and em.group(1) not in ("null",):
                emails.append(em.group(1).strip().strip("\"'"))
        cleaned = unique_emails(emails)
        if cleaned:
            mapping[agent_id] = cleaned
    return mapping


def extract_tagged_agent_ids(body: str) -> List[str]:
    ids: List[str] = []
    seen = set()
    html = body or ""
    for regex in (AGENT_HREF_RE, FRESHDESK_PROTO_RE):
        for m in regex.finditer(html):
            agent_id = m.group(1)
            if agent_id in seen:
                continue
            seen.add(agent_id)
            ids.append(agent_id)
    return ids


def resolve_note_notify(
    body: str,
    notify_emails: Optional[Sequence[str]] = None,
    staff_map: Optional[Dict[str, List[str]]] = None,
    directory: Optional[Path] = None,
) -> Dict[str, Any]:
    """Return {ok, notify_emails, tagged_agent_ids, unresolved_agent_ids, auto_added, error?}."""
    tagged = extract_tagged_agent_ids(body)
    explicit = unique_emails(notify_emails)
    mapping = staff_map if staff_map is not None else load_staff_notify_map(directory)
    merged = list(explicit)
    seen = set(explicit)
    auto_added: List[str] = []
    unresolved: List[str] = []

    for agent_id in tagged:
        emails = mapping.get(agent_id) or []
        if not emails:
            unresolved.append(agent_id)
            continue
        for email in emails:
            if email in seen:
                continue
            seen.add(email)
            merged.append(email)
            if email not in explicit:
                auto_added.append(email)

    if tagged and unresolved:
        return {
            "ok": False,
            "notify_emails": merged,
            "tagged_agent_ids": tagged,
            "unresolved_agent_ids": unresolved,
            "auto_added": auto_added,
            "error": f"agent_tag_notify_unresolved:{','.join(unresolved)}",
        }

    if tagged and not merged:
        return {
            "ok": False,
            "notify_emails": [],
            "tagged_agent_ids": tagged,
            "unresolved_agent_ids": tagged,
            "auto_added": [],
            "error": "agent_tag_notify_empty",
        }

    return {
        "ok": True,
        "notify_emails": merged,
        "tagged_agent_ids": tagged,
        "unresolved_agent_ids": [],
        "auto_added": auto_added,
    }
