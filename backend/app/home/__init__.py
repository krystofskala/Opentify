"""Domů -- žebříčky, žánry, výběry, nová vydání a osobní mixy jako hotové
sekce pro jednu obrazovku (`GET /home`). Generátory běží na pozadí
(`home_refresh_loop`) a ukládají snapshoty do DB; request jen čte."""
