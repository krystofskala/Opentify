"""slskd vrátí 409, když stejné hledání už běží -- najde se a převezme."""
import asyncio

import httpx

from app.providers import SlskdProvider


def test_running_search_is_found_by_text():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/api/v0/searches"
        return httpx.Response(200, json=[{"id": "a1", "searchText": "Peter Rowan Midnight Highway"},
                                         {"id": "b2", "searchText": "něco jiného"}])

    async def run():
        async with httpx.AsyncClient(base_url="http://slskd", transport=httpx.MockTransport(handler)) as client:
            return (
                await SlskdProvider._running_search_id(client, "peter rowan midnight highway "),
                await SlskdProvider._running_search_id(client, "nic"),
            )

    assert asyncio.run(run()) == ("a1", None)
