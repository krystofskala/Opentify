"""Zámky podle klíče pro "zkontroluj, jestli existuje, a vlož" -- souběžné
požadavky (dvojité ťuknutí, dvě zařízení, společný playlist) jinak oba
neviděly existující řádek a vložily ho dvakrát (simulace 5. 10.: oblíbený
interpret i "Na později" 3× z 5 souběžných klepnutí, playlist se stejnými
pozicemi). API běží v jednom procesu, takže stačí zámek v paměti."""

from __future__ import annotations

import threading
from contextlib import contextmanager
from typing import Iterator

_locks: dict[str, threading.Lock] = {}
_guard = threading.Lock()


@contextmanager
def keyed(key: str) -> Iterator[None]:
    with _guard:
        lock = _locks.setdefault(key, threading.Lock())
    with lock:
        yield
