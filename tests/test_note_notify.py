"""FD-414725: agent tags must resolve to notify_emails."""

from pathlib import Path

from freshdesk_mcp.note_notify import (
    extract_tagged_agent_ids,
    resolve_note_notify,
)


JOHN = "19000869163"
CAMILLE = "19000867301"
DIR = Path.home() / ".cursor" / "skills" / "corebridge-staff-directory" / "directory.yaml"


def test_extract_agent_page_anchor():
    body = (
        f'<a class="fr-deletable" href="https://supportdesk.corebridge.net/a/agents/{JOHN}">'
        "@John M</a>"
    )
    assert extract_tagged_agent_ids(body) == [JOHN]


def test_john_m_tag_auto_notifies():
    body = (
        f'<div><a class="fr-deletable" href="https://supportdesk.corebridge.net/a/agents/{JOHN}">'
        "@John M</a></div><div>V2 BUG RESEARCH</div>"
    )
    result = resolve_note_notify(body, directory=DIR)
    assert result["ok"] is True
    assert "johnm@corebridge.net" in result["notify_emails"]
    assert JOHN in result["tagged_agent_ids"]
    assert "johnm@corebridge.net" in result["auto_added"]


def test_visual_only_without_directory_entry_fails():
    body = '<a href="https://supportdesk.corebridge.net/a/agents/99999999999">@Nobody</a>'
    result = resolve_note_notify(body, directory=DIR)
    assert result["ok"] is False
    assert "99999999999" in result["unresolved_agent_ids"]


def test_explicit_notify_union_with_tag():
    body = (
        f'<a href="https://supportdesk.corebridge.net/a/agents/{CAMILLE}">@Camille Schultz</a>'
    )
    result = resolve_note_notify(
        body,
        notify_emails=["extra@corebridge.net"],
        directory=DIR,
    )
    assert result["ok"] is True
    assert "extra@corebridge.net" in result["notify_emails"]
    assert "camille@corebridge.net" in result["notify_emails"]


def test_no_tags_allows_empty_notify():
    result = resolve_note_notify("<div>Draft only</div>", directory=DIR)
    assert result["ok"] is True
    assert result["notify_emails"] == []
