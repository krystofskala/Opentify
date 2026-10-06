"""slskd 0.26 vydá odpovědi až po dokončení hledání -- běžící se zastaví (PUT)
a odpovědi se přečtou až potom (dřív 0 kandidátů z desítek odpovědí)."""
import asyncio

import httpx

import app.providers as providers
from app.providers import SlskdProvider

RESPONSES = [{"username": "peer1", "files": [{"filename": "a.flac"}]}, {"username": "peer2", "files": []}]


def _fake_slskd():
    stopped = {"value": False}

    def handler(request: httpx.Request) -> httpx.Response:
        path, method = request.url.path, request.method
        if method == "POST" and path == "/api/v0/searches":
            return httpx.Response(200, json={"id": "s1"})
        if method == "PUT" and path == "/api/v0/searches/s1":
            stopped["value"] = True
            return httpx.Response(200)
        if method == "DELETE":
            return httpx.Response(204)
        if path == "/api/v0/searches/s1":
            done = stopped["value"]
            return httpx.Response(200, json={
                "id": "s1", "isComplete": done, "responseCount": 2,
                "state": "Completed, Cancelled" if done else "InProgress",
            })
        if path == "/api/v0/searches/s1/responses":
            # Běžící hledání: prázdný seznam, i když stav hlásí odpovědi.
            return httpx.Response(200, json=RESPONSES if stopped["value"] else [])
        return httpx.Response(404)

    return handler, stopped


def test_stop_and_collect_reads_responses_after_stop():
    handler, stopped = _fake_slskd()

    async def run():
        async with httpx.AsyncClient(base_url="http://slskd", transport=httpx.MockTransport(handler)) as client:
            return await SlskdProvider._stop_and_collect(client, "s1")

    assert asyncio.run(run()) == RESPONSES
    assert stopped["value"]


def test_prune_searches_archives_then_deletes_only_old_finished(monkeypatch, tmp_path):
    deleted: list[str] = []
    searches = [
        {"id": "old", "isComplete": True, "startedAt": "2026-09-28T00:01:19.36789Z", "searchText": "a", "state": "Completed"},
        {"id": "running", "isComplete": False, "startedAt": "2026-09-28T00:01:19Z", "searchText": "b", "state": "InProgress"},
        {"id": "fresh", "isComplete": True, "startedAt": "2999-01-01T00:00:00Z", "searchText": "c", "state": "Completed"},
    ]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "DELETE":
            deleted.append(request.url.path.rsplit("/", 1)[-1])
            return httpx.Response(204)
        return httpx.Response(200, json=searches)

    real_client = httpx.AsyncClient

    class _Client(real_client):  # type: ignore[misc, valid-type]
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(handler)
            super().__init__(*args, **kwargs)

    monkeypatch.setattr(providers.httpx, "AsyncClient", _Client)
    archive = tmp_path / "history.jsonl"
    assert asyncio.run(SlskdProvider(base_url="http://slskd").prune_searches(archive=archive)) == 1
    assert deleted == ["old"]
    assert '"searchText": "a"' in archive.read_text(encoding="utf-8")


def test_read_responses_waits_for_late_save(monkeypatch):
    """slskd hlásí Completed dřív, než odpovědi uloží."""
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        return httpx.Response(200, json=RESPONSES if calls["n"] >= 3 else [])

    async def no_sleep(_s):
        return None

    monkeypatch.setattr(providers.asyncio, "sleep", no_sleep)

    async def run():
        async with httpx.AsyncClient(base_url="http://slskd", transport=httpx.MockTransport(handler)) as client:
            return (
                await SlskdProvider._read_responses(client, "s1", expected=2),
                await SlskdProvider._read_responses(client, "s1", expected=0),
            )

    calls["n"] = 0
    first, _ = asyncio.run(run())
    assert first == RESPONSES


def test_search_raw_stops_running_search(monkeypatch):
    handler, stopped = _fake_slskd()
    real_client = httpx.AsyncClient

    class _Client(real_client):  # type: ignore[misc, valid-type]
        def __init__(self, *args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(handler)
            super().__init__(*args, **kwargs)

    async def no_wait():
        return None

    monkeypatch.setattr(providers.httpx, "AsyncClient", _Client)
    monkeypatch.setattr(providers._slskd_search_limiter, "wait", no_wait)
    result = asyncio.run(SlskdProvider(base_url="http://slskd").search_raw("dope lemon", cap_s=0.5))
    assert [r["username"] for r in result] == ["peer1", "peer2"]
    assert stopped["value"]
