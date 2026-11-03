"""tests/test_verwalter_release.py -- Verwalter v16: einen Stand des Herstellers einspielen.

Aufruf (aus tests/selftest.sh):  python tests/test_verwalter_release.py <verwalter.py> <toolserver-quelle.sh> <tmp>
Exit 0 = alles bestanden, sonst ein AssertionError mit dem Befund.

git laeuft echt: ein Ursprung mit Marken, Patchdateien, die der Nachlauf wieder aus dem
Baum nimmt, und einem Startabzug, der die angewandten Patches mit sha256 nennt; die
Arbeitskopie ist ein Klon davon, tsq_setzen aus toolserver-quelle.sh setzt ihre Stufen.
Nachgebildet sind psql (ein Stand in einer Datei), dbmigrate.sh, deploy.sh und rsync.

Die Faelle (GAP-ENV-UPDATES-GITHUB-QUELLE-01 Stufe 2):
    1. v101: der fehlende Patch kommt aus der Geschichte, in der Fassung mit der
       sha256 des Herstellers (nicht in der ersten), dann Programm und Neustart
    2. dieselbe Marke noch einmal               -> nichts zu tun
    3. eine Marke neben master                  -> abgewiesen, nichts geaendert
    4. eine Fassung mit fremder Pruefsumme      -> abgewiesen, nichts geaendert
    5. ein Paket scheitert beim apply           -> die davor angewandt, Programm alt
    6. danach dieselbe Marke                    -> fertig
    7. pruefe_freigabe: falsche Art, falsche Marke, beim Hersteller
"""
import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys

spec = importlib.util.spec_from_file_location("verwalter", sys.argv[1])
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
QUELLE = os.path.abspath(sys.argv[2]).replace("\\", "/")

WURZEL = os.path.join(sys.argv[3] if len(sys.argv) > 3 else ".", "v16").replace("\\", "/")
shutil.rmtree(WURZEL, ignore_errors=True)
URSPRUNG = WURZEL + "/ursprung"
KOPIE = WURZEL + "/kopie"
TS = WURZEL + "/toolserver"
STUFEN = WURZEL + "/stufen.py"
for d in (URSPRUNG, TS):
    os.makedirs(d)
# Am Windows-Arbeitsplatz: lange Pfade und keine Zeilenendenumwandlung -- auch fuer die
# git-Aufrufe des Verwalters, die diese Umgebung erben.
os.environ.update({"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "core.longpaths",
                   "GIT_CONFIG_VALUE_0": "true", "GIT_CONFIG_KEY_1": "core.autocrlf",
                   "GIT_CONFIG_VALUE_1": "false"})


def git(verzeichnis, *argumente):
    r = subprocess.run(["git", "-C", verzeichnis] + list(argumente), capture_output=True, text=True)
    assert r.returncode == 0, "git %s: %s" % (" ".join(argumente), r.stderr)
    return r.stdout.strip()


def schreiben(pfad, inhalt):
    os.makedirs(os.path.dirname(pfad), exist_ok=True)
    with open(pfad, "w", encoding="utf-8", newline="\n") as f:
        f.write(inhalt)


def sha(inhalt):
    return hashlib.sha256(inhalt.encode("utf-8")).hexdigest()


def startabzug(staende):
    zeilen = ["-- start dump", "COPY public.schema_version (version, applied_at, description, filename, sha256) FROM stdin;"]
    zeilen += ["%d\t2026-11-03 10:00:00+00\tPatch %d\t%s\t%s" % (n, n, datei, s) for n, (datei, s) in staende]
    zeilen += ["\\.", ""]
    return "\n".join(zeilen)


def commit(nachricht, dateien=(), weg=(), marke=None):
    for pfad, inhalt in dateien:
        schreiben(URSPRUNG + "/" + pfad, inhalt)
    for pfad in weg:
        os.remove(URSPRUNG + "/" + pfad)
    git(URSPRUNG, "add", "-A")
    git(URSPRUNG, "commit", "-q", "-m", nachricht)
    if marke:
        git(URSPRUNG, "tag", marke)


A, B0, B1, C, D, E = ("-- v100\n", "-- v101 erste Fassung\n", "-- v101 angewandt\n",
                      "-- v102\n", "-- v103\n", "-- v104\n")
S100 = (100, ("v100_a.sql", sha(A)))
S101 = (101, ("v101_b.sql", sha(B1)))

git(URSPRUNG, "init", "-q", "-b", "master")
git(URSPRUNG, "config", "user.email", "test@invalid")
git(URSPRUNG, "config", "user.name", "test")
commit("v100", [("app.py", "eins\n"), ("db/patches/v100_a.sql", A),
                ("db/schema_seed.sql", startabzug([S100]))], marke="v100")
commit("Nachlauf v100, v101 geliefert", [("db/patches/v101_b.sql", B0)], weg=["db/patches/v100_a.sql"])
commit("v101 nachgebessert", [("db/patches/v101_b.sql", B1), ("app.py", "zwei\n")])
commit("Nachlauf v101", [("db/schema_seed.sql", startabzug([S100, S101]))],
       weg=["db/patches/v101_b.sql"], marke="v101")
# neben master: eine Marke, die nie freigegeben wurde
git(URSPRUNG, "checkout", "-q", "-b", "nebenzweig")
commit("v102", [("db/patches/v102_c.sql", C), ("app.py", "neben\n"),
                ("db/schema_seed.sql", startabzug([S100, S101, (102, ("v102_c.sql", sha(C)))]))], marke="v102")
git(URSPRUNG, "checkout", "-q", "master")
# auf master: ein Startabzug, dessen Pruefsumme keine Fassung der Geschichte trifft
commit("v103", [("db/patches/v103_d.sql", D), ("app.py", "drei\n"),
                ("db/schema_seed.sql", startabzug([S100, S101, (103, ("v103_d.sql", sha("anders\n")))]))],
       marke="v103")
commit("v104", [("db/patches/v104_e.sql", E), ("app.py", "vier\n"),
                ("db/schema_seed.sql", startabzug([S100, S101, (103, ("v103_d.sql", sha(D))),
                                                   (104, ("v104_e.sql", sha(E)))]))], marke="v104")

# Die Arbeitskopie: ein Klon, der auf v100 steht -- wie ein Server, der mit v100 aufgebaut wurde.
r = subprocess.run(["git", "clone", "-q", "--no-tags", URSPRUNG, KOPIE], capture_output=True, text=True)
assert r.returncode == 0, r.stderr
git(KOPIE, "fetch", "-q", "origin", "refs/tags/v100:refs/tags/v100")
git(KOPIE, "checkout", "-q", "-B", "master", "v100")
git(KOPIE, "branch", "-q", "--set-upstream-to=origin/master", "master")
schreiben(STUFEN, "import sys\nsys.stdin.read()\nprint('/*')\n")
schreiben(TS + "/app.py", "eins\n")
schreiben(TS + "/dbmigrate.sh",
          '#!/bin/bash\nH="$(cd "$(dirname "$0")" && pwd)"\necho "$*" >> "$H/dbmigrate.log"\n'
          '[ "$1" = apply ] || exit 0\n'
          '[ -f "$H/fail_on" ] && [ "$(cat "$H/fail_on")" = "$3" ] && exit 1\n'
          'echo "$3" >> "$H/applied"\n')
schreiben(TS + "/deploy.sh", '#!/bin/bash\necho deployed >> "$(cd "$(dirname "$0")" && pwd)/deploy.log"\n')
schreiben(TS + "/applied", "100\n")

beim_hersteller = [False]


def psql_read(sql):
    if "key = 'lingra'" in sql:
        return [["1"]] if beim_hersteller[0] else []
    if "platform_modules" in sql:
        return []
    staende = [z.strip() for z in open(TS + "/applied", encoding="utf-8") if z.strip()]
    if "WHERE version =" in sql:
        return [["1"]] if sql.rsplit("=", 1)[1].strip() in staende else []
    return [[n] for n in staende]


v.psql_read = psql_read
v._zwischenstand = lambda text: None
v.QUELL_KOPIE, v.STUFEN_SKRIPT, v.QUELLE_SKRIPT, v.TOOLSERVER_DIR = KOPIE, STUFEN, QUELLE, TS
v.AUFBAU_DIR = WURZEL
_echt = v._schritt_ausfuehren


def schritt(argv, verzeichnis, timeout, umgebung, text):
    """rsync gibt es nicht ueberall, wo der Selbsttest laeuft: dieselbe Kopie in Python,
    mit denselben Ausnahmen -- .git und db/patches/ kommen nie mit."""
    if argv[0] != "rsync":
        return _echt(argv, verzeichnis, timeout, umgebung, text)
    assert "--exclude=db/patches/" in argv and "--exclude=.git" in argv, argv
    quelle, ziel = argv[-2], argv[-1]
    for wurzel, ordner, dateien in os.walk(quelle):
        rel = os.path.relpath(wurzel, quelle).replace("\\", "/")
        ordner[:] = [o for o in ordner if o != ".git" and not (rel == "db" and o == "patches")]
        for d in dateien:
            os.makedirs(os.path.join(ziel, rel), exist_ok=True)
            shutil.copyfile(os.path.join(wurzel, d), os.path.join(ziel, rel, d))
    return 0


v._schritt_ausfuehren = schritt


def lesen(name):
    pfad = TS + "/" + name
    return open(pfad, encoding="utf-8").read() if os.path.exists(pfad) else ""


# 1. v101: B1 aus der Geschichte (nicht B0), Datenbank vor Programm, Neustart
text, code, erg = v.fuehre_freigabe_aus("v101")
assert code == 0, text
assert erg["angewandt"] == [101] and erg["stand"] == 101, erg
assert lesen("db/patches/v101_b.sql") == B1, "the applied version must be the publisher's"
assert lesen("dbmigrate.log").split("\n")[:2] == ["probe --to 101", "apply --to 101"], lesen("dbmigrate.log")
assert lesen("app.py") == "zwei\n", "program not at v101"
assert lesen("deploy.log").count("deployed") == 1
assert not os.path.exists(TS + "/db/patches/v100_a.sql"), "db/patches/ of the tag must not be copied"
assert git(KOPIE, "rev-parse", "HEAD") == git(URSPRUNG, "rev-parse", "v101^{commit}")
print("ok 1: v101 from the history, publisher's checksum, database before program")

# 2. noch einmal: nichts zu tun
text, code, erg = v.fuehre_freigabe_aus("v101")
assert code == 0 and "not newer" in text, text
assert lesen("deploy.log").count("deployed") == 1
print("ok 2: the same tag again changes nothing")

# 3. neben master
text, code, erg = v.fuehre_freigabe_aus("v102")
assert code == 1 and "is not on origin/master" in text, text
assert lesen("app.py") == "zwei\n" and not os.path.exists(TS + "/db/patches/v102_c.sql")
print("ok 3: a tag beside master is refused")

# 4. fremde Pruefsumme
text, code, erg = v.fuehre_freigabe_aus("v103")
assert code == 1 and "v103 (v103_d.sql): no version in the history matches" in text, text
assert "103" not in lesen("dbmigrate.log") and lesen("app.py") == "zwei\n"
print("ok 4: a checksum no version matches is refused before anything changes")

# 5. v104 scheitert beim apply: v103 angewandt, Programm alt
schreiben(TS + "/fail_on", "104\n")
text, code, erg = v.fuehre_freigabe_aus("v104")
assert code == 1 and "v104 failed in apply" in text, text
assert erg["angewandt"] == [103] and erg["halt"] == 104, erg
assert lesen("app.py") == "zwei\n" and lesen("deploy.log").count("deployed") == 1
print("ok 5: a failing patch leaves the program as it was")

# 6. danach: fertig
os.remove(TS + "/fail_on")
text, code, erg = v.fuehre_freigabe_aus("v104")
assert code == 0 and erg["angewandt"] == [104] and erg["stand"] == 104, text
assert lesen("app.py") == "vier\n" and lesen("deploy.log").count("deployed") == 2
print("ok 6: after the repair the same tag completes")

# 7. die Pruefung vor dem Lauf
os.makedirs(KOPIE + "/.git", exist_ok=True)
assert v.pruefe_freigabe("toolserver", "v104") == ("v104", "")
assert v.pruefe_freigabe("service", "v104")[1].startswith("A release belongs to the Toolserver")
assert v.pruefe_freigabe("toolserver", "v104; rm -rf /")[1].startswith("Invalid release tag")
beim_hersteller[0] = True
assert "is the publisher" in v.pruefe_freigabe("toolserver", "v104")[1]
print("ok 7: wrong kind, wrong tag and the publisher are refused")
print("test_verwalter_release: all passed")
