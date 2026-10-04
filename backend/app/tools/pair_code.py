"""Nouzový kód zařízení přímo na serveru -- když admin přijde o všechna
přihlášená zařízení (kód jinak vytváří jen přihlášený člověk).

Spuštění: `docker compose exec api python -m app.tools.pair_code <přihlašovací jméno>`
"""

from __future__ import annotations

import sys

from sqlmodel import Session, select

from app.db import engine
from app.models import AppUser
from app.routes.auth import new_pair_code


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("použití: python -m app.tools.pair_code <přihlašovací jméno>")
    username = sys.argv[1].strip().lower()
    with Session(engine) as session:
        user = next(
            (u for u in session.exec(select(AppUser)).all() if (u.username or "").lower() == username), None
        )
        if user is None:
            raise SystemExit(f"profil s přihlašovacím jménem {username!r} neexistuje")
        code, expires = new_pair_code(session, user.id, "server")
    print(f"{user.name}: kód {code} (platí do {expires:%d.%m. %H:%M} UTC, jen jednou)")


if __name__ == "__main__":
    main()
