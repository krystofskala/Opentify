"""První spuštění vlastního serveru: založí admin profil (pokud není) a vypíše
jednorázovou pozvánku. Přes ni si admin vybere přihlašovací jméno a heslo
(stejně jako pozvaní lidé) -- další zařízení pak přihlásí jménem, heslem
a kódem zařízení (Profil › Přidat zařízení).

    docker compose exec api python -m app.tools.admin_invite
"""

from __future__ import annotations

from sqlmodel import Session

from app.auth import ADMIN_ID, ensure_admin
from app.db import engine
from app.routes.auth import _INVITE_DAYS, _new_invite


def main() -> None:
    with Session(engine) as session:
        ensure_admin(session)
        code = _new_invite(session, ADMIN_ID)
    print(f"Pozvánka pro admina (platí {_INVITE_DAYS} dní, jen jednou):")
    print(f"  otevři  https://<adresa tvého serveru>/?join={code}")
    print("  a vyber si přihlašovací jméno a heslo.")


if __name__ == "__main__":
    main()
