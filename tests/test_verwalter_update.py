"""tests/test_verwalter_update.py -- Verwalter v15: Update mit Lizenzpruefung und Rueckweg (seit v14;
seit v15 prueft der Test die englische Ausgabe).

Aufruf (aus tests/selftest.sh):  python tests/test_verwalter_update.py <verwalter.py> <tmp>
Exit 0 = alles bestanden, sonst ein AssertionError mit dem Befund.

Docker, psql und GitHub sind hier nachgebildet -- ein Stapel "demo" mit zwei
Diensten (app: eine Bindung und ein benannter Datentraeger; cache: ohne Daten).
tar dagegen laeuft echt (tarfile) ueber echte Verzeichnisse: gesichert und
zurueckgespielt werden wirkliche Dateien, und am Ende wird ihr Inhalt verglichen.

Der Ablauf, den der Bediener am 2026-09-28 verlangt hat ("eine Pruefung auf
lizenzaenderungen vor updates und eine mit dem update verbundene sicherung, die
den alten Stand wieder herstellen kann"):
    1. neues Abbild, Lizenz nie angenommen   -> held, nichts geaendert
    2. Lizenz angenommen, erneut             -> Rueckweg, neuer Stand laeuft
    3. neue Fassung schreibt ihre Daten um    -> rollback: alte Daten, altes Abbild
    4. Lizenz aendert sich                    -> held, mit vorigem Text
    5. nur die Jahreszahl aendert sich        -> keine Aenderung
"""
import base64
import importlib.util
import io
import json
import os
import posixpath
import shutil
import sys
import tarfile

spec = importlib.util.spec_from_file_location("verwalter", sys.argv[1])
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)

WURZEL = os.path.join(sys.argv[2] if len(sys.argv) > 2 else ".", "v14")
shutil.rmtree(WURZEL, ignore_errors=True)
DIENST = os.path.join(WURZEL, "opt", "demo")
DATEN = os.path.join(DIENST, "daten")
VOLUME = os.path.join(WURZEL, "docker", "volumes", "demo_db", "_data")
os.makedirs(DATEN)
os.makedirs(VOLUME)
os.makedirs(os.path.join(WURZEL, "onions.one"))


def schreibe(pfad, inhalt):
    with open(pfad, "w", encoding="utf-8") as f:
        f.write(inhalt)


def lies(pfad):
    with open(pfad, encoding="utf-8") as f:
        return f.read()


schreibe(os.path.join(DATEN, "a.txt"), "alt")
schreibe(os.path.join(VOLUME, "db.txt"), "alt-db")

v.RUECKWEG_WURZEL = os.path.join(WURZEL, "backups")
v.AUFBAU_DIR = os.path.join(WURZEL, "onions.one")
v.GESUNDHEIT_SEKUNDEN = 1
v.ZWISCHENSTAND_SEKUNDEN = 0.01
v.psql_write = lambda sql: None
v._bind_zulaessig = lambda pfad: True          # die Schranke selbst: eigener Test unten

LIZENZ = "BSD 3-Clause License\n\nCopyright (c) 2024, Demo\n\nRedistribution ... permitted."
MARKE = LIZENZ + "\n\n4. Branding: the Demo name and logo must not be altered."
ZUSTAND = {
    "abbilder": {"demo/app:latest": "sha256:A1", "valkey:9": "sha256:K1"},
    "registry": {"demo/app:latest": "sha256:A2", "valkey:9": "sha256:K1"},
    "etiketten": {"sha256:A2": "rev2", "sha256:A3": "rev3", "sha256:A4": "rev4"},
    "lizenzen": {"rev2": LIZENZ, "rev3": MARKE, "rev4": MARKE.replace("2024", "2026")},
    "container": {"app": {"abbild": "sha256:A1", "zustand": "running"},
                  "cache": {"abbild": "sha256:K1", "zustand": "running"}},
    "namen": {},
    "angenommen": {},
}
CONFIG = {"name": "demo", "volumes": {"db": {"name": "demo_db"}}, "services": {
    "app": {"image": "demo/app:latest", "volumes": [
        {"type": "bind", "source": DATEN, "target": "/data"},
        {"type": "volume", "source": "db", "target": "/db"},
        {"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock", "read_only": True}]},
    "cache": {"image": "valkey:9"}}}


class Antwort:
    def __init__(self, code=0, out=""):
        self.returncode, self.stdout, self.stderr = code, out, "" if code == 0 else "Error: " + out


def kennung(name):
    if name.startswith("sha256:"):
        return name
    return ZUSTAND["abbilder"].get(name) or ZUSTAND["namen"].get(name)


def docker(argv):
    """(code, ausgabe) eines nachgebildeten docker-Aufrufs."""
    a = argv[1:]
    if a[:1] == ["compose"]:
        was = a[3]
        dienste = a[4:]
        if was == "config":
            return 0, json.dumps(CONFIG)
        if was == "pull":
            ZUSTAND["abbilder"].update(ZUSTAND["registry"])
            return 0, "pulled"
        if was in ("stop", "start"):
            for d in dienste:
                ZUSTAND["container"][d]["zustand"] = "exited" if was == "stop" else "running"
            return 0, was
        if was == "up":
            for d, e in CONFIG["services"].items():
                ZUSTAND["container"][d] = {"abbild": ZUSTAND["abbilder"][e["image"]], "zustand": "running"}
            return 0, "up"
    if a[:1] == ["ps"]:
        return 0, "\n".join("c-" + d for d in ZUSTAND["container"])
    if a[:1] == ["inspect"]:
        return 0, json.dumps([{"Name": "/demo-%s-1" % k[2:], "Image": ZUSTAND["container"][k[2:]]["abbild"],
                               "Config": {"Labels": {"com.docker.compose.service": k[2:]}},
                               "State": {"Status": ZUSTAND["container"][k[2:]]["zustand"]}} for k in a[1:]])
    if a[:2] == ["image", "inspect"]:
        k = kennung(a[2])
        if not k:
            return 1, "No such image: %s" % a[2]
        rev = ZUSTAND["etiketten"].get(k)
        etiketten = {"org.opencontainers.image.licenses": "NOASSERTION"}
        if rev:
            etiketten.update({"org.opencontainers.image.source": "https://github.com/demo/app",
                              "org.opencontainers.image.revision": rev})
        return 0, json.dumps([{"Id": k, "Config": {"Labels": etiketten}}])
    if a[:2] == ["image", "rm"]:
        ZUSTAND["abbilder"].pop(a[2], None)
        ZUSTAND["namen"].pop(a[2], None)
        return 0, "Untagged"
    if a[:1] == ["tag"]:
        ziel = ZUSTAND["namen"] if a[2].startswith(v.RUECKWEG_NAME + ":") else ZUSTAND["abbilder"]
        ziel[a[2]] = kennung(a[1])
        return 0, ""
    if a[:2] == ["volume", "inspect"]:
        return (0, json.dumps([{"Mountpoint": VOLUME}])) if a[2] == "demo_db" else (1, "no such volume")
    raise AssertionError("unerwarteter docker-Aufruf: %s" % argv)


def tar(argv):
    if "-cpf" in argv:
        ziel, quelle, name = argv[argv.index("-cpf") + 1], argv[argv.index("-C") + 1], argv[-1]
        with tarfile.open(ziel, "w") as t:
            t.add(os.path.join(quelle, name), arcname=name)
        return 0, ""
    if "-xpf" in argv:
        with tarfile.open(argv[argv.index("-xpf") + 1]) as t:
            # die eigenen Archive dieses Tests -- wie tar -xp: Rechte und Eigentuemer, wie sie sind
            t.extractall(argv[argv.index("-C") + 1],
                         **({"filter": "fully_trusted"} if hasattr(tarfile, "fully_trusted_filter") else {}))
        return 0, ""
    if "-tf" in argv:
        try:
            with tarfile.open(argv[argv.index("-tf") + 1]) as t:
                t.getnames()
            return 0, ""
        except (OSError, tarfile.TarError):
            return 2, "kaputt"
    raise AssertionError("unerwarteter tar-Aufruf: %s" % argv)


def ausfuehren(argv):
    if argv[0] == "docker":
        return docker(argv)
    if argv[0] == "tar":
        return tar(argv)
    if argv[0] == "du":
        return 0, "%d\t%s" % (sum(os.path.getsize(os.path.join(w, f)) for w, _, fs in os.walk(argv[-1]) for f in fs), argv[-1])
    raise AssertionError("unerwarteter Aufruf: %s" % argv)


def run(argv, **kw):
    code, out = ausfuehren(argv)
    return Antwort(code, out)


class Popen:
    def __init__(self, argv, **kw):
        self.returncode, out = ausfuehren(argv)
        self.stdout = iter([z + "\n" for z in out.splitlines()])

    def wait(self, timeout=None):
        return self.returncode

    def kill(self):
        pass


v.subprocess.run = run
v.subprocess.Popen = Popen


def psql_read(sql):
    if "third_party_component" in sql:
        return [["demo/app:latest", "Demo App", "https://github.com/demo/app"]] if "demo/app" in sql else []
    if "platform_license_acceptance" in sql:
        ref = sql.split("image_ref = '")[1].split("'")[0]
        return [[json.dumps(ZUSTAND["angenommen"][ref])]] if ref in ZUSTAND["angenommen"] else []
    raise AssertionError("unerwartete Abfrage: %s" % sql)


v.psql_read = psql_read


def github_lizenz(repo, fassung):
    assert repo == ("demo", "app"), repo
    text = ZUSTAND["lizenzen"][fassung]
    return {"content": base64.b64encode(text.encode()).decode(), "path": "LICENSE",
            "license": {"spdx_id": "NOASSERTION", "name": "Other"}}, "", False


v._github_lizenz = github_lizenz


def annehmen(ergebnis):
    for e in ergebnis["lizenzen"]:
        if e["stand"] in ("neu", "geaendert"):
            ZUSTAND["angenommen"][e["ref"]] = {"fingerprint": e["fingerabdruck"], "license_text": e["text"],
                                               "license_source": e["quelle"]}


# 1. neues Abbild, Lizenz nie angenommen -> held, nichts geaendert
text, code, erg = v.fuehre_update_aus(11, "demo", DIENST, "docker-compose.yml")
assert code == v.EXIT_ANGEHALTEN and erg["halt"] == "lizenz", text
assert [e["stand"] for e in erg["lizenzen"]] == ["neu"], erg["lizenzen"]
assert erg["lizenzen"][0]["quelle"] == "github.com/demo/app@rev2:LICENSE", erg["lizenzen"][0]
assert erg["dienste"]["app"]["geaendert"] and not erg["dienste"]["cache"]["geaendert"], erg["dienste"]
assert ZUSTAND["abbilder"]["demo/app:latest"] == "sha256:A1", "der Name muss wieder auf den alten Stand zeigen"
assert ZUSTAND["container"]["app"] == {"abbild": "sha256:A1", "zustand": "running"}, ZUSTAND["container"]
assert not os.path.exists(v.RUECKWEG_WURZEL), "angehalten heisst: nichts gesichert"

# 2. angenommen -> Rueckweg, neuer Stand laeuft
annehmen(erg)
text, code, erg = v.fuehre_update_aus(12, "demo", DIENST, "docker-compose.yml")
assert code == 0, text
assert [e["stand"] for e in erg["lizenzen"]] == ["unveraendert"] and "text" not in erg["lizenzen"][0]
ordner = erg["ruecksicherung"]
manifest = json.load(open(os.path.join(ordner, "manifest.json"), encoding="utf-8"))
assert manifest["geaendert"] == ["app"] and [s["art"] for s in manifest["sicherungen"]] == ["bind", "volume"], manifest
assert "mounted read-only" in text and "/var/run/docker.sock" in text, text
assert ZUSTAND["container"]["app"]["abbild"] == "sha256:A2"
assert ZUSTAND["namen"] == {"onions-rueckweg:demo-a12-1": "sha256:A1"}, ZUSTAND["namen"]

# 3. die neue Fassung schreibt ihre Daten um -> rollback
schreibe(os.path.join(DATEN, "a.txt"), "neu")
schreibe(os.path.join(DATEN, "b.txt"), "nur neu")
schreibe(os.path.join(VOLUME, "db.txt"), "neu-db")
text, code, erg = v.fuehre_rueckweg_aus(13, "demo", DIENST, "docker-compose.yml", '{"update_job": 99}')
assert code == 1 and "no way back" in text, text
text, code, erg = v.fuehre_rueckweg_aus(13, "demo", DIENST, "docker-compose.yml", '{"update_job": 12}')
assert code == 0, text
assert lies(os.path.join(DATEN, "a.txt")) == "alt" and not os.path.exists(os.path.join(DATEN, "b.txt"))
assert lies(os.path.join(VOLUME, "db.txt")) == "alt-db"
assert ZUSTAND["abbilder"]["demo/app:latest"] == "sha256:A1" and ZUSTAND["container"]["app"]["abbild"] == "sha256:A1"
with tarfile.open(os.path.join(erg["jetzt"], manifest["sicherungen"][0]["archiv"])) as t:
    assert t.extractfile("daten/a.txt").read() == b"neu", "der ersetzte Stand muss festgehalten sein"

# 4. die Lizenz aendert sich -> held, mit vorigem Text
ZUSTAND["registry"]["demo/app:latest"] = "sha256:A3"
text, code, erg = v.fuehre_update_aus(14, "demo", DIENST, "docker-compose.yml")
e = erg["lizenzen"][0]
assert code == v.EXIT_ANGEHALTEN and e["stand"] == "geaendert" and "Branding" in e["text"], text
assert e["vorher"]["license_text"] == LIZENZ, e["vorher"]
assert ZUSTAND["container"]["app"]["abbild"] == "sha256:A1"
annehmen(erg)

# 5. nur die Jahreszahl -> keine Aenderung
ZUSTAND["registry"]["demo/app:latest"] = "sha256:A4"
text, code, erg = v.fuehre_update_aus(15, "demo", DIENST, "docker-compose.yml")
assert code == 0 and erg["lizenzen"][0]["stand"] == "unveraendert", text
assert len(os.listdir(os.path.join(v.RUECKWEG_WURZEL, "demo", v.RUECKWEG_BLATT))) == v.RUECKWEG_BEHALTEN

# 6. nichts Neues -> nichts gesichert, nichts neu gestartet
text, code, erg = v.fuehre_update_aus(16, "demo", DIENST, "docker-compose.yml")
assert code == 0 and "ruecksicherung" not in erg and "nothing backed up" in text, text

# 7. bearbeite: held als Status, rollback kennt er
abgeschlossen = []
v.schliesse_ab = lambda job, status, log_text, code, erg=None: abgeschlossen.append((job, status, code))
ZUSTAND["registry"]["demo/app:latest"] = "sha256:A2"
ZUSTAND["angenommen"].clear()
v.bearbeite(("17", "demo", "update", DIENST, "docker-compose.yml", "container", "", "", "", "{}"))
assert abgeschlossen[-1] == ("17", "held", v.EXIT_ANGEHALTEN), abgeschlossen
v.bearbeite(("18", "demo", "rollback", DIENST, "docker-compose.yml", "toolserver", "", "", "", "{}"))
assert abgeschlossen[-1][1] == "failed", abgeschlossen

# 8. die Schranke fuer Bindungen, gegen Pfade des Onions-Servers
spec2 = importlib.util.spec_from_file_location("v2", sys.argv[1])
w = importlib.util.module_from_spec(spec2)
spec2.loader.exec_module(w)
w.os.path.realpath = posixpath.normpath if os.name != "posix" else w.os.path.realpath
w.AUFBAU_DIR = "/opt/onions.one"
assert w._bind_zulaessig("/opt/openwebui/volumes/data")
assert not w._bind_zulaessig("/opt/openwebui"), "das Dienstverzeichnis als Ganzes nie"
assert not w._bind_zulaessig("/var/run/docker.sock")
assert not w._bind_zulaessig("/opt/backups/openwebui/sicherung")
assert not w._bind_zulaessig("/opt/onions.one/reports")
assert not w._bind_zulaessig("/opt/../etc/passwd")
print("Verwalter v15: 8 cases passed")
