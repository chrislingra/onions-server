"""/opt/<domain>/verwalter.py -- der Verwalter eines Servers (v5)

GAP-ENV-LEITSTELLE-01 Stufe S2: der Toolserver SCHREIBT einen Auftrag in
public.platform_agent_jobs, dieser Dienst FUEHRT ihn aus. Der Web-Container
bekommt dadurch keine Macht ueber den Onions-Server -- er kennt nur die
Tabelle, und dieser Dienst kennt nur eine feste Liste von Vorgaengen.

WAS ER KANN (die feste Liste, Stand v5)
    update   Das Abbild des Dienstes auf den neuen Stand bringen, dann
             "up -d" im Verzeichnis des Dienstes. Ob dabei gezogen oder
             gebaut wird, entscheidet die Compose-Datei selbst:
               * ohne build-Abschnitt "docker compose pull"
               * mit build-Abschnitt   "docker compose build"
             Gefragt wird Docker, nicht die Datei von Hand gelesen -- so
             sind Anker, extends und Variablen genauso aufgeloest wie
             spaeter beim Start. Warum das seit v4 so ist: Graphify baut
             sein Abbild auf dem Server (graphify-toolserver:0.9.58,
             build: ./build) und liegt in keiner Registry. "pull" endete
             deshalb nach fuenf Sekunden mit "pull access denied for
             graphify-toolserver" (gemessen 2026-09-22, Auftrag #19) --
             der Knopf Update war fuer jeden selbstgebauten Dienst
             unbrauchbar. GAP-ENV-VERWALTER-ABBILD-LOKAL-01.
    restart  Toolserver: /opt/toolserver/deploy.sh (mit seinen eigenen
             Pruefungen und dem Warten auf healthy), weil der laufende
             Container sich nicht verlaesslich selbst neu starten kann
             (gemessen 2026-09-21); jeder andere Dienst: "docker compose
             restart" in seinem Verzeichnis.
    backup   (v3, 2026-09-22) das Sicherungsskript, das im Katalog beim
             Bestandteil steht -- platform_components.backup_script, ein
             Pfad INNERHALB von service_dir, also z. B.
             /opt/toolserver/scripts/pgvector_backup.sh.
    setup    (v4, 2026-09-24) das Aufbauskript, das im Katalog beim
             Bestandteil steht -- platform_components.setup_script, ein
             Dateiname im Verzeichnis dieses Dienstes hier, also z. B.
             /opt/onions.one/setup-graphify.sh. Das ist Stufe S4: einen
             Dienst aus der Oberflaeche aufbauen, statt den Befehl von
             Hand einzutippen. Die Aufbauskripte sind darauf geschrieben,
             wiederholt zu laufen; ein zweiter Lauf baut den Dienst neu
             auf, statt einen zweiten daneben zu stellen.
    module   (v5, 2026-09-25) EINE Erweiterung des Toolservers auf diesen
             Server holen: setup-module.sh <key> aus diesem Verzeichnis,
             der Key steht in platform_agent_jobs.target. Bediener: "die
             Erweiterungen werden selectiv ueber die oberflaeche nach
             Terminalinstallation geholt" -- das Terminal installiert nur
             den offenen Kern, Environment > Server-Config > Modules
             schreibt diesen Auftrag. Nur fuer den Bestandteil der Art
             toolserver; der Key muss die Form eines Modulschluessels
             haben, sonst laeuft nichts. Ob das Modul eine Erweiterung ist
             (und nie lingras eigenes), prueft setup-module.sh selbst.

    Fuer backup und setup gilt dasselbe: kein Skript im Katalog, ein
    absoluter Pfad, ein ".." oder eine Datei, die es nicht gibt -- der
    Auftrag endet sichtbar als failed, es wird nichts geraten. Aufgerufen
    wird mit festem argv ("bash <datei>"), nie ueber eine Shell -- der
    Katalog kann damit keinen Befehl einschleusen, nur eine Datei benennen.

    Was NICHT in der Liste steht, laeuft nicht. Ein Auftrag mit unbekannter
    Aktion endet als failed mit genau diesem Satz.

Bediener-Entscheid 2026-09-21 ("alles ok, lets go"): damit laeuft eine
Lieferung unbeaufsichtigt bis zum Neustart durch.

Seit v2: aendert sich diese Datei auf der Platte (der Toolserver pflegt sie
per deploy_write), beendet sich der Dienst zwischen zwei Auftraegen mit
Exit 0; systemd (Restart=always) startet ihn mit dem neuen Stand. Kein
Handgriff auf dem Onions-Server mehr noetig.

DATENBANKZUGANG: derselbe Weg wie dbmigrate.sh (docker exec
toolserver-postgres psql) -- kein neuer Netzwerkpfad, kein offener Port.
Der Postgres-Container wird von deploy.sh nicht angefasst, das Protokoll
eines Toolserver-Neustarts kommt also immer an. Lesen ueber -tAc mit einem
Trennzeichen, das in den gelesenen Werten nicht vorkommen kann
(Komponenten-Key/Verzeichnis/Dateiname sind auf Buchstaben/Ziffern/-_./
ohne Anfuehrungszeichen geprueft, siehe
envi_installation_router.py:_component_pruefen). Schreiben ueber stdin
(psql -v ON_ERROR_STOP=1 -q), damit ein beliebig langes Protokoll nie die
Kommandozeile sprengt.

WOHER ER KOMMT (seit 2026-09-25, GAP-ENV-VERWALTER-JE-INSTALLATION-01;
Bediener: "jede neuinstallation braucht einen eigenen Verwalter"): aus dem
Installer-Repository onions-server (toolserver/verwalter.py). Schritt 7 legt
ihn nach /opt/<domain>/ und richtet den Dienst onions-verwalter ein -- jeder
Server hat seinen eigenen. Nicht im Repository des Toolservers. Auf dem
Onions-Server liegt dieselbe Datei unter /opt/onions.one und wird per
deploy_write byte-gleich gehalten (sha256 vergleichen).
"""
import json
import os
import re
import subprocess
import sys
import time
import traceback
from datetime import datetime, timezone

PG_CONTAINER = "toolserver-postgres"
PG_USER = "toolserver"
PG_DB = "toolserver"
POLL_SECONDS = 5
FS = "\x1f"  # ASCII unit separator -- kann in einem geprueften Key/Pfad nicht vorkommen
TOOLSERVER_KIND = "toolserver"
TOOLSERVER_DIR = "/opt/toolserver"
EIGENE_DATEI = os.path.abspath(__file__)
#: Die Aufbauskripte (setup-<dienst>.sh) liegen im selben Verzeichnis wie diese
#: Datei -- /opt/<domain>. Kein zweiter Ort, keine Einstellung, die abweichen
#: koennte: der Verwalter liegt dort, wo er sie findet.
AUFBAU_DIR = os.path.dirname(EIGENE_DATEI)
#: Eine Sicherung darf lange dauern (Archive von mehreren Gigabyte), aber nicht
#: ewig -- sonst haelt ein haengendes Skript die Warteschlange fuer immer.
SICHERUNG_TIMEOUT = 3600
#: Ein Aufbau baut Abbilder, zieht Pakete und fuellt Daten -- der Graphify-Aufbau
#: brauchte am 2026-09-21 gemessene 3192 Sekunden. Zwei Stunden sind die Grenze,
#: ab der ein Lauf nicht mehr laeuft, sondern haengt.
AUFBAU_TIMEOUT = 7200
#: Das Skript, das eine Erweiterung holt (Aktion module), und die Form eines
#: Modulschluessels (platform_modules.key) -- dieselbe, die setup-module.sh prueft.
MODUL_SKRIPT = "setup-module.sh"
MODUL_KEY = re.compile(r"^[a-z][a-z0-9_]{1,39}$")
#: Ziehen ist ein Netzzugriff, Bauen ist Arbeit. Deshalb zwei Grenzen.
ZIEH_TIMEOUT = 900
BAU_TIMEOUT = 3600


def log(msg):
    print("%s %s" % (datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"), msg), flush=True)


def psql_read(sql):
    """-tAc mit FS als Feldtrenner; eine Zeile je Ergebniszeile."""
    out = subprocess.run(
        ["docker", "exec", PG_CONTAINER, "psql", "-U", PG_USER, "-d", PG_DB,
         "-tA", "-F", FS, "-c", sql],
        capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError("psql read failed: %s" % (out.stderr or out.stdout))
    return [ln.split(FS) for ln in out.stdout.splitlines() if ln.strip()]


def pg_escape(s):
    return (s or "").replace("\x00", "").replace("'", "''")


def psql_write(sql):
    """Ueber stdin, wie dbmigrate.sh:psql_in() -- kein Zeilenlimit der Kommandozeile."""
    out = subprocess.run(
        ["docker", "exec", "-i", PG_CONTAINER, "psql", "-U", PG_USER, "-d", PG_DB,
         "-v", "ON_ERROR_STOP=1", "-q"],
        input=sql, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError("psql write failed: %s" % (out.stderr or out.stdout))


def naechster_auftrag():
    rows = psql_read(
        "SELECT j.id, j.component_key, j.action, c.service_dir, c.compose_file, c.kind, "
        "COALESCE(c.backup_script, ''), COALESCE(c.setup_script, ''), COALESCE(j.target, '') "
        "FROM public.platform_agent_jobs j "
        "JOIN public.platform_components c ON c.key = j.component_key "
        "WHERE j.status = 'pending' ORDER BY j.id LIMIT 1")
    return rows[0] if rows else None


def markiere_laufend(job_id):
    psql_write("UPDATE public.platform_agent_jobs SET status = 'running', "
               "started_at = now() WHERE id = %s;" % int(job_id))


def schliesse_ab(job_id, status, log_text, exit_code):
    psql_write(
        "UPDATE public.platform_agent_jobs SET status = '%s', finished_at = now(), "
        "log = '%s', exit_code = %s WHERE id = %s;"
        % (pg_escape(status), pg_escape(log_text[-8000:]),
           "NULL" if exit_code is None else int(exit_code), int(job_id)))


def _verzeichnis(service_dir):
    d = service_dir.strip()
    return d if d.startswith("/") else ("/opt/" + d.strip("/"))


def _schritte_ausfuehren(schritte, verzeichnis, timeout):
    """Schritte nacheinander im Verzeichnis; Abbruch beim ersten Fehler. Gibt
    (log_text, exit_code) zurueck -- exit_code des ERSTEN Schritts mit Fehler,
    sonst der des letzten."""
    text = []
    for schritt in schritte:
        text.append("$ %s   (in %s)" % (" ".join(schritt), verzeichnis))
        try:
            r = subprocess.run(schritt, cwd=verzeichnis, capture_output=True,
                               text=True, timeout=timeout)
        except Exception as exc:  # noqa: BLE001 -- der Auftrag endet sichtbar als failed
            text.append("Exception: %s" % exc)
            return "\n".join(text), 1
        text.append(r.stdout)
        if r.stderr:
            text.append(r.stderr)
        text.append("exit %s" % r.returncode)
        if r.returncode != 0:
            return "\n".join(text), r.returncode
    return "\n".join(text), 0


def baut_selbst(compose_file, verzeichnis):
    """(baut, grund) -- hat die Compose-Datei einen build-Abschnitt?

    Gefragt wird Docker selbst ("docker compose config"), nicht die YAML-Datei
    von Hand gelesen: Anker (&basis / <<: *basis), extends und Variablen aus
    der .env sind dort genauso aufgeloest, wie sie es beim Start sein werden.
    Graphify z. B. traegt build und image nur im Anker, nicht im Dienst.

    Laesst sich die Frage nicht beantworten, gibt es keine Antwort -- der
    Grund wird zurueckgegeben und der Auftrag scheitert sichtbar
    (R-NO-SILENT-FALLBACK-01). Auf gut Glueck zu ziehen waere genau der
    Fehler, den v4 abstellt.
    """
    try:
        r = subprocess.run(
            ["docker", "compose", "-f", compose_file, "config", "--format", "json"],
            cwd=verzeichnis, capture_output=True, text=True, timeout=120)
    except Exception as exc:  # noqa: BLE001 -- der Auftrag endet sichtbar als failed
        return None, "Die Compose-Datei liess sich nicht lesen: %s" % exc
    if r.returncode != 0:
        return None, ("Die Compose-Datei %s liess sich nicht lesen (exit %s):\n%s"
                      % (compose_file, r.returncode, (r.stderr or r.stdout).strip()))
    try:
        daten = json.loads(r.stdout)
    except ValueError as exc:
        return None, ("Die Antwort von 'docker compose config' war kein JSON (%s) -- "
                      "damit ist nicht zu entscheiden, ob gebaut oder gezogen wird." % exc)
    dienste = daten.get("services")
    if not isinstance(dienste, dict) or not dienste:
        return None, "In %s steht kein einziger Dienst -- da ist nichts zu aktualisieren." % compose_file
    for eintrag in dienste.values():
        if isinstance(eintrag, dict) and eintrag.get("build"):
            return True, ""
    return False, ""


def fuehre_update_aus(service_dir, compose_file):
    """Abbild auf den neuen Stand bringen, dann "up -d" -- gebaut oder gezogen,
    je nachdem, was die Compose-Datei sagt (siehe baut_selbst)."""
    verzeichnis = _verzeichnis(service_dir)
    baut, grund = baut_selbst(compose_file, verzeichnis)
    if grund:
        return grund, 1
    if baut:
        kopf = ("Die Compose-Datei hat einen build-Abschnitt: das Abbild wird auf diesem\n"
                "Server gebaut, nicht aus einer Registry gezogen.\n")
        schritte = [["docker", "compose", "-f", compose_file, "build"],
                    ["docker", "compose", "-f", compose_file, "up", "-d"]]
        timeout = BAU_TIMEOUT
    else:
        kopf = "Kein build-Abschnitt: das Abbild wird gezogen.\n"
        schritte = [["docker", "compose", "-f", compose_file, "pull"],
                    ["docker", "compose", "-f", compose_file, "up", "-d"]]
        timeout = ZIEH_TIMEOUT
    text, code = _schritte_ausfuehren(schritte, verzeichnis, timeout)
    return kopf + text, code


def fuehre_neustart_aus(kind, service_dir, compose_file):
    """Toolserver: deploy.sh (mit seinen eigenen Pruefungen und dem Warten auf
    healthy). Fremder Dienst: docker compose restart in seinem Verzeichnis."""
    if kind == TOOLSERVER_KIND:
        return _schritte_ausfuehren(
            [["bash", os.path.join(TOOLSERVER_DIR, "deploy.sh")]], TOOLSERVER_DIR, 900)
    return _schritte_ausfuehren(
        [["docker", "compose", "-f", compose_file, "restart"]],
        _verzeichnis(service_dir), 900)


def pruefe_sicherungsskript(service_dir, backup_script):
    """(Datei, Grund) -- der Grund ist der Satz, mit dem der Auftrag scheitert.

    Ein Sicherungsskript ist ein Pfad INNERHALB des Dienstverzeichnisses. Alles
    andere -- leer, absolut, mit '..', mit Anfuehrungszeichen, nicht vorhanden --
    wird nicht ausgefuehrt, sondern benannt (R-NO-SILENT-FALLBACK-01).
    """
    name = (backup_script or "").strip()
    if not name:
        return "", "Kein Sicherungsskript im Katalog hinterlegt (platform_components.backup_script)."
    if name.startswith("/") or ".." in name or any(ch in name for ch in "\n\r\t\"'`$;|&"):
        return "", "Unzulaessiger Skriptname '%s' -- erwartet wird ein Pfad im Dienstverzeichnis." % name
    if not (service_dir or "").strip():
        return "", "Kein Verzeichnis fuer den Dienst hinterlegt -- ohne das laeuft kein Skript."
    datei = os.path.join(_verzeichnis(service_dir), name)
    if not os.path.isfile(datei):
        return "", "Sicherungsskript nicht gefunden: %s" % datei
    return datei, ""


def fuehre_sicherung_aus(service_dir, datei):
    """Das Sicherungsskript des Dienstes, in seinem Verzeichnis, festes argv."""
    return _schritte_ausfuehren([["bash", datei]], _verzeichnis(service_dir),
                                SICHERUNG_TIMEOUT)


def pruefe_aufbauskript(setup_script):
    """(Datei, Grund) -- wie pruefe_sicherungsskript, nur fuer den Aufbau.

    Ein Aufbauskript ist ein blosser DATEINAME in AUFBAU_DIR (/opt/<domain>),
    kein Pfad: dort liegen sie alle nebeneinander, und der Katalog traegt sie
    genauso ein (setup-graphify.sh). Ein Schraegstrich waere deshalb schon die
    erste Abweichung und wird benannt, nicht zurechtgebogen.
    """
    name = (setup_script or "").strip()
    if not name:
        return "", "Kein Aufbauskript im Katalog hinterlegt (platform_components.setup_script)."
    if "/" in name or ".." in name or any(ch in name for ch in "\n\r\t\"'`$;|&"):
        return "", ("Unzulaessiger Skriptname '%s' -- erwartet wird ein Dateiname in %s."
                    % (name, AUFBAU_DIR))
    datei = os.path.join(AUFBAU_DIR, name)
    if not os.path.isfile(datei):
        return "", "Aufbauskript nicht gefunden: %s" % datei
    return datei, ""


def fuehre_aufbau_aus(datei):
    """Das Aufbauskript, in seinem eigenen Verzeichnis, festes argv.

    Es laeuft als root -- dieser Dienst ist ein systemd-Dienst des
    Onions-Servers. Genau dafuer gibt es ihn: der Toolserver-Container darf
    das nicht, und von Hand soll es niemand mehr eintippen muessen.
    """
    return _schritte_ausfuehren([["bash", datei]], AUFBAU_DIR, AUFBAU_TIMEOUT)


def pruefe_modulauftrag(kind, target):
    """(Datei, Grund) -- eine Erweiterung holt nur der Bestandteil Toolserver,
    und nur mit einem Key in der Form eines Modulschluessels. Alles andere wird
    benannt, nicht ausgefuehrt (R-NO-SILENT-FALLBACK-01)."""
    if kind != TOOLSERVER_KIND:
        return "", "Eine Erweiterung gehoert zum Toolserver, nicht zu einem Bestandteil der Art '%s'." % kind
    key = (target or "").strip()
    if not MODUL_KEY.match(key):
        return "", "Unzulaessiger Modulschluessel '%s' -- erwartet: Kleinbuchstaben, Ziffern, _." % key
    datei = os.path.join(AUFBAU_DIR, MODUL_SKRIPT)
    if not os.path.isfile(datei):
        return "", "%s nicht gefunden -- dieser Server wurde nicht vom Installer eingerichtet." % datei
    return datei, ""


def fuehre_modul_aus(datei, key):
    """setup-module.sh <key>, festes argv, im Verzeichnis der Aufbauskripte."""
    return _schritte_ausfuehren([["bash", datei, key]], AUFBAU_DIR, AUFBAU_TIMEOUT)


def bearbeite(auftrag):
    (job_id, component_key, action, service_dir, compose_file, kind,
     backup_script, setup_script, target) = auftrag
    log("Auftrag #%s: %s / %s%s" % (job_id, component_key, action, (" " + target) if target else ""))
    markiere_laufend(job_id)
    if action == "update":
        if not compose_file or not service_dir:
            schliesse_ab(job_id, "failed",
                         "Kein Verzeichnis oder keine Compose-Datei fuer '%s' hinterlegt." % component_key, None)
            return
        lauf = lambda: fuehre_update_aus(service_dir, compose_file)  # noqa: E731
    elif action == "restart":
        if kind != TOOLSERVER_KIND and (not compose_file or not service_dir):
            schliesse_ab(job_id, "failed",
                         "Kein Verzeichnis oder keine Compose-Datei fuer '%s' hinterlegt." % component_key, None)
            return
        lauf = lambda: fuehre_neustart_aus(kind, service_dir, compose_file)  # noqa: E731
    elif action == "backup":
        datei, grund = pruefe_sicherungsskript(service_dir, backup_script)
        if grund:
            schliesse_ab(job_id, "failed", grund, None)
            return
        lauf = lambda: fuehre_sicherung_aus(service_dir, datei)  # noqa: E731
    elif action == "setup":
        datei, grund = pruefe_aufbauskript(setup_script)
        if grund:
            schliesse_ab(job_id, "failed", grund, None)
            return
        lauf = lambda: fuehre_aufbau_aus(datei)  # noqa: E731
    elif action == "module":
        datei, grund = pruefe_modulauftrag(kind, target)
        if grund:
            schliesse_ab(job_id, "failed", grund, None)
            return
        lauf = lambda: fuehre_modul_aus(datei, target.strip())  # noqa: E731
    else:
        schliesse_ab(job_id, "failed",
                     "Unbekannte Aktion '%s' -- v5 kennt 'update', 'restart', 'backup', "
                     "'setup' und 'module'." % action, None)
        return
    try:
        text, code = lauf()
    except Exception:  # noqa: BLE001 -- der Auftrag endet sichtbar, der Dienst laeuft weiter
        schliesse_ab(job_id, "failed", "Unerwarteter Fehler:\n%s" % traceback.format_exc(), None)
        return
    schliesse_ab(job_id, "ok" if code == 0 else "failed", text, code)
    log("Auftrag #%s beendet: %s" % (job_id, "ok" if code == 0 else "failed"))


def eigene_datei_geaendert(stand):
    try:
        return os.stat(EIGENE_DATEI).st_mtime != stand
    except OSError:
        return False


def main():
    stand = os.stat(EIGENE_DATEI).st_mtime
    log("verwalter.py v5 gestartet, Abfrage alle %ss" % POLL_SECONDS)
    while True:
        try:
            auftrag = naechster_auftrag()
            if auftrag:
                bearbeite(auftrag)
                continue
        except Exception:  # noqa: BLE001 -- ein Abfragefehler beendet den Dienst nie
            log("Fehler bei der Abfrage:\n%s" % traceback.format_exc())
        if eigene_datei_geaendert(stand):
            log("verwalter.py auf der Platte geaendert -- Ende mit Exit 0, systemd startet den neuen Stand.")
            return 0
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main())
