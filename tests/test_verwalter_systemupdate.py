"""tests/test_verwalter_systemupdate.py -- Verwalter v17: die Pakete des Servers (os_update).

Aufruf (aus tests/selftest.sh):  python tests/test_verwalter_systemupdate.py <verwalter.py> <tmp>
Exit 0 = alles bestanden, sonst ein AssertionError mit dem Befund.

Nachgebildet sind systemctl, systemd-run, shutdown und uname (subprocess.run) und die
Datenbank (psql_read / psql_write); apt laeuft nie. Die Einheit "schreibt" ihre Ausgabe,
indem die Nachbildung von systemd-run die Logdatei anlegt.

Die Faelle:
    1. apt gelingt, der Server verlangt einen Neustart, reboot=true  -> shutdown -r +1, ok,
       Pakete und Neustartpakete im Ergebnis, Abschrift fuer die CRA-Stueckliste
    2. dasselbe ohne reboot                                         -> kein shutdown, "ausstehend"
    3. apt scheitert (Endmarke 100)                                 -> Exit 100, kein shutdown
    4. die Einheit endet ohne Endmarke                              -> Exit 1 mit Grund
    5. Wiederaufnahme: ein Auftrag steht auf running, seine Logdatei liegt schon da
       -> kein zweites systemd-run, der Auftrag wird abgeschlossen
    6. das Ende eines Auftrags geht mehrmals hinaus, wenn die Datenbank kurz weg ist
    7. os_update nur am Bestandteil der Art toolserver
    8. (v18) dpkg scheitert auch nach der Reparatur -> pakete_fehler nennt das Paket, kein shutdown;
       die Einheit laeuft mit LC_ALL=C, und das Skript traegt den Reparaturgang
"""
import importlib.util
import os
import shutil
import sys
import types

spec = importlib.util.spec_from_file_location("verwalter", sys.argv[1])
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

WURZEL = os.path.join(sys.argv[2] if len(sys.argv) > 2 else ".", "v17").replace("\\", "/")
shutil.rmtree(WURZEL, ignore_errors=True)
os.makedirs(WURZEL + "/run")
os.makedirs(WURZEL + "/etc")
os.makedirs(WURZEL + "/dpkg")

v.OS_UPDATE_LOG = WURZEL + "/log/os-update-%d.log"
v.HOST_INFO_DIR = WURZEL + "/host-info"
v.NEUSTART_NOETIG = WURZEL + "/run/reboot-required"
v.ZWISCHENSTAND_SEKUNDEN = 0
v.SCHLUSS_PAUSE = 0
v.time = types.SimpleNamespace(monotonic=v.time.monotonic, sleep=lambda s: None)

with open(WURZEL + "/dpkg/status", "w") as f:
    f.write("Package: linux-image-6.8.0-149-generic\nStatus: install ok installed\n")
with open(WURZEL + "/etc/os-release", "w") as f:
    f.write('ID=ubuntu\nVERSION_ID="24.04"\n')
_echt_kopie = shutil.copyfile


def _kopie(quelle, ziel):
    quelle = {"/var/lib/dpkg/status": WURZEL + "/dpkg/status", "/etc/os-release": WURZEL + "/etc/os-release"}.get(quelle, quelle)
    if quelle.startswith("/var/run/"):
        quelle = WURZEL + "/run/" + quelle[len("/var/run/"):]
    return _echt_kopie(quelle, ziel)


v.shutil = types.SimpleNamespace(copyfile=_kopie, rmtree=shutil.rmtree)
_isfile = os.path.isfile
v.os = types.SimpleNamespace(**{k: getattr(os, k) for k in dir(os) if not k.startswith("__")})
v.os.path = types.SimpleNamespace(**{k: getattr(os.path, k) for k in dir(os.path) if not k.startswith("__")})
v.os.path.isfile = lambda p: _isfile(WURZEL + "/run/" + p[len("/var/run/"):]) if p.startswith("/var/run/") else _isfile(p)

AUSGABE = {}      # job_id -> was die Einheit in ihre Logdatei schreibt
AUFRUFE = []


class R:
    def __init__(self, code=0, out="", err=""):
        self.returncode, self.stdout, self.stderr = code, out, err


def _run(argv, **kw):
    AUFRUFE.append(list(argv))
    if argv[0] == "systemctl":
        return R(3)                                   # die Einheit laeuft nicht (mehr)
    if argv[0] == "systemd-run":
        einheit = argv[argv.index("--unit") + 1]
        job = int(einheit.rsplit("-", 1)[1])
        datei = v.OS_UPDATE_LOG % job
        os.makedirs(os.path.dirname(datei), exist_ok=True)
        with open(datei, "w") as f:
            f.write(AUSGABE[job])
        return R(0)
    if argv[0] == "shutdown":
        return R(0)
    if argv[0] == "uname":
        return R(0, "6.8.0-137-generic\n")
    raise AssertionError("unexpected command %r" % argv)


v.subprocess = types.SimpleNamespace(run=_run)
GUT = ("== apt-get update\n== apt-get upgrade\nSetting up linux-image-6.8.0-149-generic (6.8.0-149.149) ...\n"
       "Setting up libxslt1.1:amd64 (1.1.39-0exp1ubuntu0.24.04.2) ...\n== apt-get autoremove\n"
       "ONIONS_OS_UPDATE_EXIT=0\n")


def neustart_verlangt(ja):
    for name in ("reboot-required", "reboot-required.pkgs"):
        pfad = WURZEL + "/run/" + name
        if ja:
            with open(pfad, "w") as f:
                f.write("linux-image-6.8.0-149-generic\n" if name.endswith("pkgs") else "*** System restart required ***\n")
        elif os.path.exists(pfad):
            os.remove(pfad)


def shutdowns():
    return [a for a in AUFRUFE if a[0] == "shutdown"]


# 1. gelingt, Neustart verlangt und gewuenscht
AUSGABE[1] = GUT
neustart_verlangt(True)
text, code, erg = v.fuehre_systemupdate_aus(1, '{"reboot": true}')
assert code == 0, text
assert erg["neustart"] == "geplant" and len(shutdowns()) == 1 and shutdowns()[0][:3] == ["shutdown", "-r", "+1"], erg
assert erg["pakete"] == ["linux-image-6.8.0-149-generic 6.8.0-149.149", "libxslt1.1 1.1.39-0exp1ubuntu0.24.04.2"], erg
assert erg["neustart_pakete"] == ["linux-image-6.8.0-149-generic"] and erg["kernel_laeuft"] == "6.8.0-137-generic", erg
for name in ("dpkg-status", "os-release", "reboot-required", "reboot-required.pkgs"):
    assert os.path.isfile(v.HOST_INFO_DIR + "/" + name), name
assert "copied to" in text, text

# 2. ohne Wunsch: kein shutdown, ausstehend
AUSGABE[2] = GUT
text, code, erg = v.fuehre_systemupdate_aus(2, "{}")
assert code == 0 and erg["neustart"] == "ausstehend" and len(shutdowns()) == 1, erg
assert "was not restarted" in text, text

# 3. apt scheitert: Exit der Endmarke, kein shutdown -- und ohne Neustartvermerk wird die Abschrift bereinigt
AUSGABE[3] = "== apt-get update\nE: Could not get lock\nONIONS_OS_UPDATE_EXIT=100\n"
neustart_verlangt(False)
text, code, erg = v.fuehre_systemupdate_aus(3, '{"reboot": true}')
assert code == 100 and erg["neustart"] == "nicht_noetig" and len(shutdowns()) == 1, (code, erg)
assert not os.path.exists(v.HOST_INFO_DIR + "/reboot-required"), "stale reboot mark left in host-info"

# 4. die Einheit endet ohne Endmarke
AUSGABE[4] = "== apt-get update\n"
text, code, erg = v.fuehre_systemupdate_aus(4, "{}")
assert code == 1 and "without its end mark" in text, text

# 5. Wiederaufnahme: Logdatei liegt schon da -> kein zweites systemd-run
os.makedirs(os.path.dirname(v.OS_UPDATE_LOG % 5), exist_ok=True)
with open(v.OS_UPDATE_LOG % 5, "w") as f:
    f.write(GUT)
vorher = len([a for a in AUFRUFE if a[0] == "systemd-run"])
GESCHRIEBEN = []
v.psql_read = lambda sql: [["5", "{}"]] if "os_update" in sql else []
v.psql_write = lambda sql: GESCHRIEBEN.append(sql)
v.systemupdate_wiederaufnehmen()
assert len([a for a in AUFRUFE if a[0] == "systemd-run"]) == vorher, "a second unit was started"
assert len(GESCHRIEBEN) == 1 and "status = 'ok'" in GESCHRIEBEN[0] and "WHERE id = 5" in GESCHRIEBEN[0], GESCHRIEBEN

# 6. das Ende geht mehrmals hinaus
FEHLER = [2]


def _wackelig(sql):
    if FEHLER[0]:
        FEHLER[0] -= 1
        raise RuntimeError("psql read failed: container restarting")
    GESCHRIEBEN.append(sql)


v.psql_write = _wackelig
v.schliesse_ab(6, "ok", "x", 0)
assert "WHERE id = 6" in GESCHRIEBEN[-1] and FEHLER[0] == 0, GESCHRIEBEN

# 7. nur am Bestandteil der Art toolserver
GESCHRIEBEN.clear()
v.psql_write = lambda sql: GESCHRIEBEN.append(sql)
v.bearbeite(["7", "docserver", "os_update", "/opt/docserver", "x.yml", "container", "", "", "", "{}"])
assert "status = 'failed'" in GESCHRIEBEN[-1] and "Toolserver component" in GESCHRIEBEN[-1], GESCHRIEBEN
# 8. (v18) scheitert trotz Reparatur: das Paket steht im Ergebnis
AUSGABE[8] = "\n".join([
    "== apt-get upgrade", "Setting up apparmor (4.0.1) ...",
    "Errors were encountered while processing:", " crowdsec-firewall-bouncer-nftables",
    "E: Sub-process /usr/bin/dpkg returned an error code (1)", "== repair: dpkg --configure -a",
    "Errors were encountered while processing:", " crowdsec-firewall-bouncer-nftables",
    "== failed services", "-- crowdsec-firewall-bouncer.service", "ONIONS_OS_UPDATE_EXIT=100", ""])
neustart_verlangt(True)
vorher = len(shutdowns())
text, code, erg = v.fuehre_systemupdate_aus(8, '{"reboot": true}')
assert code == 100 and erg["pakete_fehler"] == ["crowdsec-firewall-bouncer-nftables"], erg
assert len(shutdowns()) == vorher and erg["neustart"] == "ausstehend", erg
assert "even after the repair" in text, text
lauf = [a for a in AUFRUFE if a[0] == "systemd-run"][-1]
assert "--setenv=LC_ALL=C" in lauf, lauf
assert "dpkg --force-confdef --force-confold --configure -a" in v.OS_UPDATE_SKRIPT
assert "second pass" in v.OS_UPDATE_SKRIPT and "journalctl -u" in v.OS_UPDATE_SKRIPT
print("Verwalter v20 os_update: 8 cases passed")
