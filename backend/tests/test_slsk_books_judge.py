"""Audiokniha ze Soulseeku: přechodná chyba jednoho souboru knihu neshodí
(živě 7. 10.: 3 ze 4 souborů stažené, jeden "User appears to be offline")."""
from app.spoken.slsk_books import MAX_ATTEMPTS, judge

FILES = [{"filename": f"book\{i}.mp3", "size": 100} for i in range(1, 5)]


def t(state, at="2026-10-07T20:00:00", done=0):
    return {"state": state, "requestedAt": at, "bytesTransferred": done}


def test_one_offline_file_is_retried_not_failed():
    by = {f["filename"]: [t("Completed, Succeeded", done=100)] for f in FILES[:3]}
    by[FILES[3]["filename"]] = [t("Completed, Errored")]
    share, state, retry, reason = judge(by, FILES)
    assert state == "retry" and retry == [FILES[3]] and reason is None and 0.7 < share < 1


def test_rejected_means_try_another_version():
    by = {FILES[0]["filename"]: [t("Completed, Rejected")]}
    assert judge(by, FILES)[1:4:2] == ("failed", "Soulseek: uživatel tyhle soubory nesdílí, zkus jinou verzi")


def test_gives_up_after_max_attempts():
    by = {FILES[0]["filename"]: [t("Completed, Errored", at=f"2026-10-07T20:0{i}:00") for i in range(MAX_ATTEMPTS)]}
    assert judge(by, FILES)[1] == "failed"


def test_queued_remotely_keeps_downloading_and_done_when_all_succeeded():
    by = {FILES[0]["filename"]: [t("Queued, Remotely")]}
    assert judge(by, FILES)[1] == "downloading"
    by = {f["filename"]: [t("Completed, Errored", at="1"), t("Completed, Succeeded", at="2", done=100)] for f in FILES}
    assert judge(by, FILES)[:2] == (1.0, "done")
