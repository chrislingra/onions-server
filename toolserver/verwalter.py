"""/opt/<domain>/verwalter.py -- der Verwalter eines Servers (v14)

GAP-ENV-LEITSTELLE-01 Stufe S2: der Toolserver SCHREIBT einen Auftrag in
public.platform_agent_jobs, dieser Dienst FUEHRT ihn aus. Der Web-Container
bekommt dadurch keine Macht ueber den Onions-Server -- er kennt nur die
Tabelle, und dieser Dienst kennt nur eine feste Liste von Vorgaengen.

WAS ER KANN (die feste Liste, Stand v8)
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
    host     (v6, 2026-09-26) EINE Arbeit am Server selbst: host-task.sh <arbeit>
             aus diesem Verzeichnis. Die Arbeit steht in target und muss in
             HOST_ARBEITEN stehen; ihre Werte (Admin, oeffentlicher Schluessel)
             in params -- hier noch einmal geprueft und als Umgebung HT_USER /
             HT_KEY uebergeben, nie auf der Kommandozeile. Bediener 2026-09-26:
             "staging umstellen / email/ Smtp nachbearbeiten / ssh-Zugriff
             einrichten / weitere Haertungsschritte" -- die Einrichtungsseite
             des Toolservers (Environment > Installation > Setup) schreibt den
             Auftrag. Fuer harden_mail holt der Verwalter den SMTP-Zugang aus
             dem Toolserver (docker exec ... svc_hostaufgaben relay) und reicht
             ihn auf stdin weiter: das Kennwort steht weder in der Tabelle noch
             im Protokoll.
    probe    (v7, 2026-09-26) der PROBELAUF eines Aufbauskripts: dasselbe
             Skript aus dem Katalog wie setup (platform_components.setup_script),
             dieselben Pruefungen, dasselbe feste argv, dieselbe Frist --
             zusaetzlich der Umgebungswert ONIONS_PROBELAUF=1, eine Konstante;
             nichts aus der Datenbank fliesst in Befehl oder Umgebung.
             setup-graphify.sh baut damit einen kleinen Graphen nach
             out/testlauf, der Graph des Projekts bleibt unberuehrt. Bediener
             2026-09-23: "das ist als testlauf ein bisschen zu aufwendig und muss
             bald moeglichst in eine GUI integriert werden" -- der Knopf Test run
             unter Environment > Installation schreibt den Auftrag
             (GAP-ENV-VERWALTER-PROBELAUF-01). SCHUTZ: ein Aufbauskript, das den
             Wert nicht kennt, ueberliest ihn und faehrt den VOLLEN Aufbau
             (gemessen 3192 s bis 10834 s, Modellkosten). probe laeuft deshalb
             nur, wenn der Skripttext die Zeichenfolge ONIONS_PROBELAUF enthaelt,
             sonst endet der Auftrag als failed mit genau diesem Grund. Eine
             eigene Aktion und kein Feld an setup: ein Verwalter vor v7 endet
             mit "Unbekannte Aktion 'probe'", nie mit einem vollen Aufbau.

    module_remove  (v12, 2026-09-27) EINE Erweiterung wieder vom Server nehmen:
             remove-module.sh <key> aus diesem Verzeichnis -- das Gegenstueck
             zu module, mit denselben Pruefungen (Bestandteil toolserver, Form
             des Schluessels). Die Daten der Erweiterung bleiben; ob sie
             entfernt werden darf (Stufe addon, keine andere haengt an ihr),
             prueft remove-module.sh selbst. Eine eigene Aktion und kein Feld
             an module: ein Verwalter vor v12 endet mit "Unbekannte Aktion",
             nie mit einem Holen (GAP-ENV-ERWEITERUNG-ENTFERNEN-01).

    rollback (v14, 2026-09-28) den Stand VOR einem Update wiederherstellen: die
             Daten aus dem Rueckweg, den dieses Update angelegt hat, und die
             alten Abbilder unter ihren alten Namen, dann "up -d". Welches
             Update, steht in params ({"update_job": <id>}). Siehe UPDATE MIT
             LIZENZPRUEFUNG UND RUECKWEG.

    Fuer backup, setup und probe gilt dasselbe: kein Skript im Katalog, ein
    absoluter Pfad, ein ".." oder eine Datei, die es nicht gibt -- der
    Auftrag endet sichtbar als failed, es wird nichts geraten. Aufgerufen
    wird mit festem argv ("bash <datei>"), nie ueber eine Shell -- der
    Katalog kann damit keinen Befehl einschleusen, nur eine Datei benennen.

    Was NICHT in der Liste steht, laeuft nicht. Ein Auftrag mit unbekannter
    Aktion endet als failed mit genau diesem Satz.

FORTSCHRITT (v8, 2026-09-26): waehrend ein Auftrag laeuft, steht seine Ausgabe
schon in platform_agent_jobs.log -- alle ZWISCHENSTAND_SEKUNDEN der Stand, nur
wenn neue Zeilen da sind, und nur, solange die Zeile auf running steht. Bis v7
kam das Protokoll erst mit dem Ende: ein Aufbau von 5705 s (Auftrag #206) war
eine Stunde lang nur "running". Bediener 2026-09-23 zum Probelauf: "sieht
Fortschritt und Ergebnis dort" (GAP-GF-LAUF-AUS-DEM-BILDSCHIRM-01); die
Oberflaeche zeigt die letzte Zeile. stdout und stderr kommen dafuer in einem
Strom, in der Reihenfolge, in der das Skript sie schreibt. Die Zeitgrenze
bleibt, was sie war: danach wird das Skript beendet und der Auftrag endet als
failed. Ausgenommen ist host (host-task.sh bekommt fuer harden_mail den
SMTP-Zugang auf stdin und laeuft wie bisher am Stueck).

ZEITGRENZE DES AUFBAUS (v9, 2026-09-27): sechs statt zwei Stunden. Der volle
Bau des Graphify-Projekts toolserver brauchte am 2026-09-27 gemessene 10834 s
(/opt/graphify/out/bau.log) -- seit Toolserver v1897 liest er jedes
Handbuchkapitel in einem eigenen Block. setup-graphify.sh faehrt diesen Bau
mit; mit 7200 s haette der Verwalter jeden Set up mitten im Bau beendet. Und
beendet wird nur die aeussere bash: der Bau laeuft verwaist weiter, der Schritt
"Dienste starten" am Ende des Skripts laeuft nie, graphify und graphify-pflege
blieben angehalten -- der Code Graph waere fuer alle Sitzungen weg, bis jemand
eingreift. Sechs Stunden sind wieder rund das Doppelte des laengsten gemessenen
Laufs, derselbe Abstand wie vorher (7200 s zu 3192 s). Dass ein langer Aufbau so
lange jeden anderen Auftrag anhaelt, bleibt: GAP-ENV-VERWALTER-LANGER-AUFTRAG-
SPERRT-01.

ARBEIT harden_trivy (v10, 2026-09-27): ersetzt harden_scout. Docker Scout steht
unter Dockers Abovertrag (nur Binaerdateien, Anmeldung mit Docker-Hub-Konto),
Trivy unter Apache-2.0 (GAP-ENV-DOCKER-SCOUT-ERSETZEN-01). Dieselbe Liste steht
in host-task.sh und im Toolserver (services/svc_hostaufgaben.py, ab v1923).

ARBEIT trivy_scan (v11, 2026-09-27): jedes Abbild eines laufenden Containers durch
Trivy -- bekannte Schwachstellen und die Lizenzen der Pakete darin. Das Ergebnis
schreibt host-task.sh nach /opt/<domain>/reports/trivy-scan.json, nicht ins
Protokoll (das behielt bis v12 nur die letzten 8000 Zeichen); der Toolserver liest es unter
/host-opt (Security > Server Hardening > Image Scan, v1953,
GAP-ENV-TRIVY-ERGEBNIS-MASKE-01).

VOLLES PROTOKOLL (v13, 2026-09-27): in platform_agent_jobs.log steht die ganze
Ausgabe eines Auftrags -- am Ende wie zwischendurch. Bis v12 waren es nur die
letzten 8000 Zeichen (PROTOKOLL_ZEICHEN, seit v8 fuer die Fortschrittsanzeige
gesetzt); zwischendurch sogar nur die letzten 400 Zeilen des laufenden Schritts.
Bediener 2026-09-27: "warum nicht alles aus log in db?" -- einen Grund gab es
nicht: die Spalte ist text, geschrieben wird ueber stdin, und ein voller
Graphify-Bau schreibt gemessene 156 KB (/opt/graphify/out/bau.log vom
2026-09-27). Gekuerzt wird erst ab der Schutzgrenze PROTOKOLL_GRENZE
(2 000 000 Zeichen): dann bleiben Anfang und Ende, und eine Zeile dazwischen
sagt, wie viel fehlt -- ein Skript, das endlos schreibt, sprengt die Zeile nicht
(GAP-ENV-VERWALTER-PROTOKOLL-VOLL-01).

UPDATE MIT LIZENZPRUEFUNG UND RUECKWEG (v14, 2026-09-28, Toolserver v2039,
GAP-ENV-UPDATE-LIZENZ-RUECKWEG-01). Bediener: "watchtower entfaellt voellig und
wird durch unsere neuen Funktionen ersetzt ... was fehlt ist eine Pruefung auf
lizenzaenderungen vor updates und eine mit dem update verbundene sicherung, die
den alten Stand wieder herstellen kann". Bis v13 hiess update: ziehen, "up -d" --
der alte Stand war danach nicht mehr zu haben (die Abbilder heissen main oder
latest, der Name wandert mit), und eine neue Fassung baut beim ersten Start ihre
Datenbank um. Seit v14 in dieser Reihenfolge:
    1. holen (pull oder build) -- das startet nichts, die Dienste laufen weiter;
    2. vergleichen: welcher Dienst bekaeme ein anderes Abbild als das, mit dem
       sein Container laeuft? Keiner -> fertig, nichts gesichert, nichts neu;
    3. Lizenz je neuem Abbild: der Lizenztext der neuen Fassung (ueber die
       Quelle und Fassung, die das Abbild in seinen Etiketten nennt, sonst ueber
       die GitHub-Adresse im Register) gegen den zuletzt angenommenen
       (public.platform_license_acceptance). Neu oder anders -> ANGEHALTEN
       (Status held, Exit 3): die Namen zeigen wieder auf den alten Stand,
       nichts ist geaendert; die Oberflaeche zeigt alten und neuen Text, und
       wer annimmt, stoesst das Update neu an;
    4. Rueckweg: die geaenderten Dienste anhalten, ihre beschreibbaren Daten
       (benannte Datentraeger, Bindungen unter /opt/<dienst>/) nach
       /opt/backups/<key>/vor-update/<stempel>-auftrag<id>/ sichern, jedes
       Archiv zurueckgelesen, die alten Abbilder unter onions-rueckweg:...
       festhalten, manifest.json schreiben;
    5. "up -d", dann warten, bis die neuen Dienste laufen (und gesund melden);
    6. aeltere Rueckwege dieses Dienstes raeumen (RUECKWEG_BEHALTEN bleiben).
rollback spielt einen solchen Rueckweg zurueck -- und haelt vorher den Stand, den
er ersetzt, im selben Ordner fest (vor-rueckweg-<stempel>/): auch der Rueckweg
laesst sich zuruecknehmen.

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
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
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
#: faehrt den vollen Bau mit, und der brauchte am 2026-09-27 gemessene 10834
#: Sekunden (am 2026-09-21 noch 3192). Sechs Stunden, rund das Doppelte, sind die
#: Grenze, ab der ein Lauf nicht mehr laeuft, sondern haengt (v9; bis v8 7200).
AUFBAU_TIMEOUT = 6 * 3600
#: Der Umgebungswert des Probelaufs (Aktion probe). Er ist zugleich die Zeichenfolge,
#: die ein Aufbauskript tragen muss, damit probe es startet -- ein Skript ohne sie
#: wuerde den Wert ueberlesen und den vollen Aufbau fahren.
PROBE_MARKE = "ONIONS_PROBELAUF"
#: Das Skript, das eine Erweiterung holt (Aktion module), und die Form eines
#: Modulschluessels (platform_modules.key) -- dieselbe, die setup-module.sh prueft.
MODUL_SKRIPT = "setup-module.sh"
#: Das Gegenstueck (Aktion module_remove, v12).
MODUL_ENTFERNEN_SKRIPT = "remove-module.sh"
MODUL_KEY = re.compile(r"^[a-z][a-z0-9_]{1,39}$")
#: Die Arbeiten am Server (Aktion host) -- dieselbe Liste wie in host-task.sh und in
#: services/svc_hostaufgaben.py des Toolservers. Wert: die Angaben, die sie braucht.
HOST_SKRIPT = "host-task.sh"
HOST_ARBEITEN = {
    "status": (), "ssh_key": ("user", "key"), "ssh_harden": (), "user_add": ("user", "key"),
    "harden_mail": (), "harden_intrusion": (), "harden_updates": (), "harden_rkhunter": (),
    "rkhunter_off": (), "harden_trivy": (), "trivy_scan": (), "cert_production": (),
}
HOST_BENUTZER = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
HOST_SCHLUESSEL = re.compile(
    r"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]{40,16384}( [A-Za-z0-9._@+:-]{1,100})?$")
#: Pakete holen und installieren (CrowdSec, rkhunter) darf dauern, aber nicht ewig.
HOST_TIMEOUT = 1800
#: Ziehen ist ein Netzzugriff, Bauen ist Arbeit. Deshalb zwei Grenzen.
ZIEH_TIMEOUT = 900
BAU_TIMEOUT = 3600
#: Wie oft der Stand eines laufenden Auftrags ins Protokoll geht (v8). Die Oberflaeche
#: fragt alle drei Sekunden -- schneller als hier geschrieben wird, sieht sie nichts.
ZWISCHENSTAND_SEKUNDEN = 15
#: Das Protokoll steht ganz in der Tabelle -- am Ende wie zwischendurch (v13; bis v12
#: nur die letzten 8000 Zeichen). Erst ueber PROTOKOLL_GRENZE Zeichen wird gekuerzt:
#: die ersten PROTOKOLL_ANFANG Zeichen und das Ende bleiben, dazwischen eine Zeile.
PROTOKOLL_GRENZE = 2000000
PROTOKOLL_ANFANG = 200000
#: Der Rueckweg eines Updates (v14): /opt/backups/<key>/vor-update/<stempel>-auftrag<id>/
#: -- die Sicherungen eines Dienstes liegen unter /opt/backups/<dienst>
#: (R-SICHERUNG-JE-DIENST-01), dieser Zweig daneben.
RUECKWEG_WURZEL = "/opt/backups"
RUECKWEG_BLATT = "vor-update"
RUECKWEG_ORDNER = re.compile(r"^\d{8}-\d{6}-auftrag(\d+)$")
#: So viele Rueckwege bleiben je Dienst liegen; aeltere gehen nach einem gelungenen
#: Update samt ihren Namen weg. Zwei: der des letzten Updates und der davor.
RUECKWEG_BEHALTEN = 2
#: Das Repository der Namen, die ein altes Abbild festhalten. Ohne Namen raeumt
#: "docker image prune" es weg, sobald kein Container es mehr benutzt.
RUECKWEG_NAME = "onions-rueckweg"
#: So lange wartet ein Update (und ein Rueckweg) darauf, dass die neu gestarteten
#: Dienste laufen und, wo sie eine Gesundheitspruefung haben, gesund melden.
GESUNDHEIT_SEKUNDEN = 240
#: Exit-Code eines angehaltenen Updates: eine Lizenz ist neu oder geaendert und
#: wartet auf ihre Annahme. Status held -- nichts ist geaendert.
EXIT_ANGEHALTEN = 3
#: Wie GitHub die Lizenzdatei eines Repositorys nennt (zu einer Fassung: ?ref=).
GITHUB_LIZENZ = "https://api.github.com/repos/%s/%s/license"
GITHUB_REPO = re.compile(
    r"^(?:https?://|git@)?(?:www\.)?github\.com[/:]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$")
#: Der Auftrag, der gerade laeuft (bearbeite setzt ihn; es laeuft immer nur einer).
_laufender_auftrag = None


class _Abbruch(Exception):
    """Ein Schritt des Rueckwegs ist gescheitert -- der Grund ist der Text."""


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
        "COALESCE(c.backup_script, ''), COALESCE(c.setup_script, ''), COALESCE(j.target, ''), "
        "COALESCE(j.params::text, '{}') "
        "FROM public.platform_agent_jobs j "
        "JOIN public.platform_components c ON c.key = j.component_key "
        "WHERE j.status = 'pending' ORDER BY j.id LIMIT 1")
    return rows[0] if rows else None


def markiere_laufend(job_id):
    psql_write("UPDATE public.platform_agent_jobs SET status = 'running', "
               "started_at = now() WHERE id = %s;" % int(job_id))


def _protokoll(log_text):
    """Das Protokoll fuer die Tabelle (v13): ganz, bis PROTOKOLL_GRENZE Zeichen.
    Darueber bleiben der Anfang und das Ende, dazwischen steht, wie viele Zeichen
    fehlen -- was ein Skript zuerst und zuletzt sagte, bleibt so immer lesbar."""
    text = log_text or ""
    if len(text) <= PROTOKOLL_GRENZE:
        return text
    ende = PROTOKOLL_GRENZE - PROTOKOLL_ANFANG
    return "%s\n[verwalter] ... %d Zeichen ausgelassen (Schutzgrenze %d Zeichen) ...\n%s" % (
        text[:PROTOKOLL_ANFANG], len(text) - PROTOKOLL_GRENZE, PROTOKOLL_GRENZE, text[-ende:])


def schliesse_ab(job_id, status, log_text, exit_code, ergebnis=None):
    """ergebnis (v14): was die Oberflaeche lesen muss, nicht nur anzeigen -- die
    Lizenzen eines angehaltenen Updates, der Ordner des Rueckwegs. Als JSON in
    platform_agent_jobs.result; ohne ergebnis bleibt die Spalte, wie sie ist."""
    zusatz = ""
    if ergebnis is not None:
        zusatz = ", result = '%s'::jsonb" % pg_escape(json.dumps(ergebnis, ensure_ascii=False))
    psql_write(
        "UPDATE public.platform_agent_jobs SET status = '%s', finished_at = now(), "
        "log = '%s', exit_code = %s%s WHERE id = %s;"
        % (pg_escape(status), pg_escape(_protokoll(log_text)),
           "NULL" if exit_code is None else int(exit_code), zusatz, int(job_id)))


def _zwischenstand(log_text):
    """Den Stand des laufenden Auftrags ins Protokoll -- nur, solange er auf running
    steht. Ein Fehler hier haelt den Auftrag nie an; er steht im Journal des Dienstes."""
    if _laufender_auftrag is None:
        return
    try:
        psql_write("UPDATE public.platform_agent_jobs SET log = '%s' WHERE id = %s AND status = 'running';"
                   % (pg_escape(_protokoll(log_text)), int(_laufender_auftrag)))
    except Exception as exc:  # noqa: BLE001 -- Anzeige, kein Teil des Auftrags
        log("Zwischenstand zu Auftrag #%s nicht geschrieben: %s" % (_laufender_auftrag, exc))


def _verzeichnis(service_dir):
    d = service_dir.strip()
    return d if d.startswith("/") else ("/opt/" + d.strip("/"))


def _schritte_ausfuehren(schritte, verzeichnis, timeout, umgebung=None):
    """Schritte nacheinander im Verzeichnis; Abbruch beim ersten Fehler. Gibt
    (log_text, exit_code) zurueck -- exit_code des ERSTEN Schritts mit Fehler,
    sonst der des letzten. umgebung=None erbt die des Dienstes."""
    text = []
    for schritt in schritte:
        text.append("$ %s   (in %s)" % (" ".join(schritt), verzeichnis))
        code = _schritt_ausfuehren(schritt, verzeichnis, timeout, umgebung, text)
        if code is None:
            return "\n".join(text), 1
        text.append("exit %s" % code)
        if code != 0:
            return "\n".join(text), code
    return "\n".join(text), 0


def _schritt_ausfuehren(schritt, verzeichnis, timeout, umgebung, text):
    """Ein Schritt. Seine Ausgabe -- stdout und stderr in einem Strom, in der
    Reihenfolge, in der sie kommt -- landet Zeile fuer Zeile in text, und
    waehrenddessen alle ZWISCHENSTAND_SEKUNDEN im Protokoll des laufenden
    Auftrags (v8). Gibt den Exit-Code zurueck; None, wenn der Schritt nicht
    startete oder die Zeitgrenze erreichte -- der Grund steht dann in text."""
    try:
        proc = subprocess.Popen(schritt, cwd=verzeichnis, env=umgebung, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors="replace", bufsize=1)
    except Exception as exc:  # noqa: BLE001 -- der Auftrag endet sichtbar als failed
        text.append("Exception: %s" % exc)
        return None
    zeilen = []

    def lesen():
        for zeile in proc.stdout:
            zeilen.append(zeile.rstrip("\n"))

    leser = threading.Thread(target=lesen, daemon=True)
    leser.start()
    frist = time.monotonic() + timeout
    gemeldet = 0
    while True:
        try:
            proc.wait(timeout=ZWISCHENSTAND_SEKUNDEN)
            break
        except subprocess.TimeoutExpired:
            pass
        if time.monotonic() >= frist:
            proc.kill()
            proc.wait()
            leser.join(10)
            text.extend(zeilen)
            text.append("Zeitgrenze erreicht: '%s' nach %s s beendet." % (" ".join(schritt), timeout))
            return None
        stand = list(zeilen)
        if len(stand) != gemeldet:
            gemeldet = len(stand)
            _zwischenstand("\n".join(text + stand))
    leser.join(10)
    text.extend(zeilen)
    return proc.returncode


def compose_config(compose_file, verzeichnis):
    """(daten, grund) -- die Compose-Datei, wie Docker sie beim Start aufloest.

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
    return daten, ""


def baut_selbst(compose_file, verzeichnis):
    """(baut, grund) -- hat die Compose-Datei einen build-Abschnitt?"""
    daten, grund = compose_config(compose_file, verzeichnis)
    if grund:
        return None, grund
    return any(isinstance(e, dict) and e.get("build") for e in daten["services"].values()), ""


def _dienste(daten):
    """{dienst: {"ref", "baut", "mounts": [{"art", "quelle", "ro"}]}} aus der
    aufgeloesten Compose-Datei. ref ist der Name, unter dem "up -d" das Abbild
    nimmt: image, sonst der Name, den Compose einem gebauten gibt
    (<projekt>-<dienst>). Ein benannter Datentraeger traegt seinen echten Namen
    (<projekt>_<name>, so steht er unter volumes der aufgeloesten Datei)."""
    projekt = daten.get("name") or ""
    datentraeger = daten.get("volumes") or {}
    ergebnis = {}
    for name, e in daten["services"].items():
        if not isinstance(e, dict):
            continue
        mounts = []
        for v in e.get("volumes") or []:
            if not isinstance(v, dict) or not v.get("source"):
                continue
            if v.get("type") == "volume":
                echt = (datentraeger.get(v["source"]) or {}).get("name") or v["source"]
                mounts.append({"art": "volume", "quelle": echt, "ro": bool(v.get("read_only"))})
            elif v.get("type") == "bind":
                mounts.append({"art": "bind", "quelle": v["source"], "ro": bool(v.get("read_only"))})
        ergebnis[name] = {"ref": e.get("image") or "%s-%s" % (projekt, name),
                          "baut": bool(e.get("build")), "mounts": mounts}
    return ergebnis


def _docker_json(argumente, timeout=120):
    """(daten, grund) -- ein docker-Aufruf, dessen Antwort JSON ist."""
    try:
        r = subprocess.run(["docker"] + argumente, capture_output=True, text=True, timeout=timeout)
    except Exception as exc:  # noqa: BLE001 -- der Grund geht an den Aufrufer
        return None, "docker %s: %s" % (" ".join(argumente[:2]), exc)
    if r.returncode != 0:
        return None, "docker %s (exit %s): %s" % (" ".join(argumente[:2]), r.returncode,
                                                  (r.stderr or r.stdout).strip()[-600:])
    try:
        return json.loads(r.stdout), ""
    except ValueError as exc:
        return None, "docker %s: keine JSON-Antwort (%s)" % (" ".join(argumente[:2]), exc)


def _abbild(ref):
    """Die Angaben des Abbilds unter diesem Namen oder dieser Kennung (docker image
    inspect) -- None, wenn es hier keins gibt."""
    daten, grund = _docker_json(["image", "inspect", ref])
    return daten[0] if not grund and daten else None


def _container_stand(projekt):
    """({dienst: {"container", "abbild", "zustand", "gesundheit"}}, grund) -- die
    Container des Stapels, wie sie jetzt sind (auch angehaltene), erkannt am
    Compose-Etikett des Projekts."""
    try:
        r = subprocess.run(["docker", "ps", "-aq", "--filter",
                            "label=com.docker.compose.project=%s" % projekt],
                           capture_output=True, text=True, timeout=60)
    except Exception as exc:  # noqa: BLE001 -- der Grund geht an den Aufrufer
        return None, "docker ps: %s" % exc
    if r.returncode != 0:
        return None, "docker ps (exit %s): %s" % (r.returncode, (r.stderr or r.stdout).strip())
    kennungen = r.stdout.split()
    if not kennungen:
        return {}, ""
    daten, grund = _docker_json(["inspect"] + kennungen)
    if grund:
        return None, grund
    stand = {}
    for c in daten:
        dienst = ((c.get("Config") or {}).get("Labels") or {}).get("com.docker.compose.service")
        if dienst:
            zustand = c.get("State") or {}
            stand[dienst] = {"container": (c.get("Name") or "").lstrip("/"), "abbild": c.get("Image") or "",
                             "zustand": zustand.get("Status") or "",
                             "gesundheit": (zustand.get("Health") or {}).get("Status") or ""}
    return stand, ""


def _lauf(text, schritt, verzeichnis, timeout):
    """Ein Schritt mit Kopf- und Schlusszeile in text; sein Fortschritt geht mit dem
    ganzen bisherigen text ins Protokoll. Gibt den Exit-Code zurueck -- -1, wenn der
    Schritt nicht startete oder die Zeitgrenze erreichte: das ist kein Exit-Code des
    Programms (tar meldet mit 1 eine Warnung, und die ist etwas anderes)."""
    text.append("$ %s   (in %s)" % (" ".join(schritt), verzeichnis))
    code = _schritt_ausfuehren(schritt, verzeichnis, timeout, None, text)
    text.append("exit %s" % ("-" if code is None else code))
    return -1 if code is None else code


def _namen_zurueck(vorher, text):
    """Jeden Namen wieder auf das Abbild, auf das er vor dem Holen zeigte. Einen
    Namen, den es vorher nicht gab, nimmt er wieder weg -- sonst startete ein
    spaeteres "up -d" den neuen, nicht angenommenen Stand."""
    for ref, alt in sorted(vorher.items()):
        if (_abbild(ref) or {}).get("Id") == alt:
            continue
        _lauf(text, ["docker", "tag", alt, ref] if alt else ["docker", "image", "rm", ref], "/", 60)


# -- Lizenz ----------------------------------------------------------------------

def _github_repo(url):
    m = GITHUB_REPO.match((url or "").strip())
    return (m.group(1), m.group(2)) if m else None


def _github_lizenz(repo, fassung):
    """(daten, grund, fehlt) -- die Lizenzdatei, wie GitHub sie im Repository
    erkennt, zur Fassung fassung (leer: Hauptzweig). fehlt=True heisst: GitHub
    kennt dort keine (404) -- ein Befund, kein Netzfehler."""
    url = GITHUB_LIZENZ % repo
    if fassung:
        url += "?ref=" + urllib.parse.quote(fassung, safe="")
    anfrage = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "User-Agent": "onions-verwalter"})
    try:
        with urllib.request.urlopen(anfrage, timeout=30) as antwort:
            return json.loads(antwort.read().decode("utf-8")), "", False
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None, "GitHub kennt in %s/%s%s keine Lizenzdatei." % (
                repo[0], repo[1], (" zur Fassung " + fassung[:12]) if fassung else ""), True
        return None, "GitHub antwortete mit HTTP %s auf %s" % (exc.code, url), False
    except Exception as exc:  # noqa: BLE001 -- der Grund geht an den Aufrufer
        return None, "GitHub nicht erreichbar (%s): %s" % (url, exc), False


def _normal(text):
    """Der Vergleichstext: Jahreszahlen gleichgesetzt, Leerraum zusammengezogen --
    ein neues Jahr im Copyright-Vermerk ist keine neue Lizenz, ein neuer Satz schon."""
    return " ".join(re.sub(r"\b(?:19|20)\d{2}\b", "JJJJ", text or "").split())


def _lizenz_lesen(abbild, origin_url):
    """(lizenz, grund). lizenz: {"spdx", "name", "angabe", "quelle", "herkunft",
    "hinweis", "text", "fingerabdruck"}. grund ist ein technischer Fehler (Netz,
    GitHub) -- dann ist nichts zu entscheiden, das Update endet als failed.

    Gelesen wird der Lizenztext DER FASSUNG, die das Abbild in seinen Etiketten
    nennt (org.opencontainers.image.source + .revision). Die Etikette .licenses
    allein taugt nicht: das Abbild von Open WebUI traegt dort NOASSERTION
    (gemessen 2026-09-28). Nennt das Abbild keine GitHub-Quelle, dann die
    GitHub-Adresse aus dem Register, am Hauptzweig. Gibt es keinen Text, ist
    auch das ein Stand -- "ohne Text", mit der Etikette als Fingerabdruck; er
    wird angezeigt und angenommen wie jeder andere, nie still durchgewunken."""
    etiketten = (abbild.get("Config") or {}).get("Labels") or {}
    angabe = (etiketten.get("org.opencontainers.image.licenses") or "").strip()
    repo = _github_repo(etiketten.get("org.opencontainers.image.source")
                        or etiketten.get("org.label-schema.vcs-url") or "")
    fassung = ((etiketten.get("org.opencontainers.image.revision")
                or etiketten.get("org.label-schema.vcs-ref") or "").strip() if repo else "")
    herkunft = "image"
    if not repo:
        repo, fassung, herkunft = _github_repo(origin_url), "", "register"
    hinweis = ""
    if repo:
        daten, grund, fehlt = _github_lizenz(repo, fassung)
        if fehlt and fassung:
            hinweis = "Fassung %s bei GitHub nicht gefunden, gelesen am Hauptzweig. " % fassung[:12]
            fassung = ""
            daten, grund, fehlt = _github_lizenz(repo, "")
        if grund and not fehlt:
            return None, grund
        if daten:
            try:
                text = base64.b64decode(daten.get("content") or "").decode("utf-8", "replace")
            except (ValueError, TypeError) as exc:
                return None, "Die Lizenzdatei von GitHub liess sich nicht lesen: %s" % exc
            art = daten.get("license") or {}
            return {"spdx": art.get("spdx_id") or "", "name": art.get("name") or "", "angabe": angabe,
                    "quelle": "github.com/%s/%s@%s:%s" % (repo[0], repo[1], fassung[:12] or "HEAD",
                                                         daten.get("path") or "?"),
                    "herkunft": herkunft, "hinweis": hinweis.strip(), "text": text,
                    "fingerabdruck": "sha256:" + hashlib.sha256(_normal(text).encode("utf-8")).hexdigest()}, ""
        hinweis += grund + " "
    hinweis += ("Kein Lizenztext feststellbar: das Abbild nennt keine GitHub-Quelle"
                + ("." if _github_repo(origin_url) else ", das Register keine GitHub-Adresse."))
    return {"spdx": angabe, "name": "", "angabe": angabe, "quelle": "", "herkunft": herkunft,
            "hinweis": hinweis.strip(), "text": "",
            "fingerabdruck": "ohne-text:" + hashlib.sha256(angabe.encode("utf-8")).hexdigest()}, ""


def _registerzeile(ref):
    """(component_key, name, origin_url) der Registerzeile fuer diesen Abbildnamen
    -- oder None. ollama/ollama und ollama/ollama:latest sind derselbe Name."""
    kandidaten = {ref}
    if ref.endswith(":latest"):
        kandidaten.add(ref[:-len(":latest")])
    elif ":" not in ref.rsplit("/", 1)[-1]:
        kandidaten.add(ref + ":latest")
    rows = psql_read(
        "SELECT component_key, COALESCE(name, ''), COALESCE(origin_url, '') "
        "FROM governance.third_party_component WHERE active AND component_key IN (%s) "
        "ORDER BY component_key LIMIT 1" % ", ".join("'%s'" % pg_escape(k) for k in sorted(kandidaten)))
    return rows[0] if rows else None


def _angenommen(ref):
    """Die zuletzt angenommene Lizenz dieses Abbildnamens -- oder None. Als JSON
    gelesen: der Lizenztext traegt Zeilenumbrueche, eine Zeile je Wert traegt er nicht."""
    rows = psql_read(
        "SELECT row_to_json(a)::text FROM (SELECT fingerprint, license_spdx, license_name, "
        "license_source, license_text, accepted_at, accepted_by "
        "FROM public.platform_license_acceptance WHERE image_ref = '%s' "
        "ORDER BY accepted_at DESC, id DESC LIMIT 1) a" % pg_escape(ref))
    return json.loads(rows[0][0]) if rows else None


def _lizenzen_pruefen(dienste, geaendert, ergebnis, text):
    """(angehalten, grund) -- je neuem Abbild die Lizenz gegen die zuletzt
    angenommene. grund: ein technischer Fehler, das Update endet als failed."""
    angehalten = False
    for ref in sorted({dienste[d]["ref"] for d in geaendert}):
        if any(dienste[d]["baut"] for d in geaendert if dienste[d]["ref"] == ref):
            ergebnis["lizenzen"].append({"ref": ref, "stand": "gebaut"})
            text.append("Lizenz %s: auf diesem Server gebaut -- geprueft werden gezogene Abbilder; "
                        "was ein Bau hereinholt, legt seine Dockerfile fest." % ref)
            continue
        zeile = _registerzeile(ref)
        lizenz, grund = _lizenz_lesen(_abbild(ref) or {}, zeile[2] if zeile else "")
        if grund:
            return angehalten, "Die Lizenz von %s liess sich nicht lesen: %s" % (ref, grund)
        vorige = _angenommen(ref)
        if vorige and vorige.get("fingerprint") == lizenz["fingerabdruck"]:
            stand = "unveraendert"
            lizenz.pop("text", None)
        else:
            stand = "geaendert" if vorige else "neu"
            angehalten = True
            lizenz["vorher"] = vorige or {}
        lizenz.update({"ref": ref, "stand": stand, "register": zeile[0] if zeile else "",
                       "register_name": zeile[1] if zeile else ""})
        ergebnis["lizenzen"].append(lizenz)
        text.append("Lizenz %s: %s -- %s %s" % (
            ref, {"unveraendert": "unveraendert", "neu": "NOCH NIE ANGENOMMEN",
                  "geaendert": "GEAENDERT"}[stand],
            lizenz["spdx"] or lizenz["angabe"] or "?", lizenz["quelle"] or lizenz["hinweis"]))
    return angehalten, ""


# -- Rueckweg --------------------------------------------------------------------

def _bind_zulaessig(pfad):
    """Eine Bindung wird nur gesichert und zurueckgespielt, wenn sie unter
    /opt/<dienst>/... liegt -- mindestens zwei Ebenen unter /opt, nicht in den
    Sicherungen selbst, nicht bei den Aufbauskripten. /var/run/docker.sock,
    /etc/localtime und das Dienstverzeichnis als Ganzes bleiben aussen vor: sie
    aendert kein Update, und zurueckgespielt werden duerfen sie nie."""
    echt = os.path.realpath(pfad)
    teile = echt.strip("/").split("/")
    return (len(teile) >= 3 and teile[0] == "opt"
            and not (echt + "/").startswith(RUECKWEG_WURZEL + "/")
            and not (echt + "/").startswith(AUFBAU_DIR.rstrip("/") + "/"))


def _datentraeger_ort(name):
    """(ort, grund) -- wo ein benannter Datentraeger auf der Platte liegt. ort leer
    und grund leer: es gibt ihn (noch) nicht -- nichts zu sichern."""
    daten, grund = _docker_json(["volume", "inspect", name])
    if grund:
        return "", ("" if "no such volume" in grund.lower() else grund)
    return (daten[0].get("Mountpoint") or "") if daten else "", ""


def _zu_sichern(dienste, geaendert, text):
    """(liste, grund) -- die beschreibbaren Datentraeger und Bindungen der
    geaenderten Dienste, jeder einmal, mit seinem Ort auf der Platte."""
    liste, gesehen = [], set()
    for d in geaendert:
        for m in dienste[d]["mounts"]:
            if (m["art"], m["quelle"]) in gesehen:
                continue
            gesehen.add((m["art"], m["quelle"]))
            if m["ro"]:
                text.append("  nur lesend eingebunden, bleibt unveraendert: %s" % m["quelle"])
                continue
            if m["art"] == "bind":
                if not _bind_zulaessig(m["quelle"]):
                    text.append("  nicht gesichert (liegt nicht unter /opt/<dienst>/): %s" % m["quelle"])
                    continue
                if not os.path.exists(m["quelle"]):
                    text.append("  nicht gesichert (gibt es nicht): %s" % m["quelle"])
                    continue
                ort = os.path.realpath(m["quelle"])
            else:
                ort, grund = _datentraeger_ort(m["quelle"])
                if grund:
                    return None, "Datentraeger %s: %s" % (m["quelle"], grund)
                if not ort:
                    text.append("  nicht gesichert (Datentraeger gibt es noch nicht): %s" % m["quelle"])
                    continue
            name = re.sub(r"[^A-Za-z0-9_.-]+", "_", m["quelle"].strip("/"))[-40:]
            liste.append({"dienst": d, "art": m["art"], "quelle": m["quelle"], "ort": ort,
                          "archiv": "%02d-%s-%s.tar" % (len(liste) + 1, m["art"], name)})
    return liste, ""


def _groesse(pfad):
    try:
        r = subprocess.run(["du", "-sb", pfad], capture_output=True, text=True, timeout=1800)
        return int(r.stdout.split()[0])
    except (subprocess.SubprocessError, OSError, IndexError, ValueError):
        return 0


def _platz_pruefen(eintraege, ordner_eltern):
    """Grund, wenn nicht genug Platz ist -- die Daten einmal und ein Zehntel dazu."""
    bedarf = sum(_groesse(e["ort"]) for e in eintraege)
    frei = shutil.disk_usage(ordner_eltern).free
    if bedarf + bedarf // 10 > frei:
        return "Nicht genug Platz unter %s: %d MB noetig, %d MB frei. Nichts geaendert." % (
            ordner_eltern, bedarf // 1048576, frei // 1048576)
    return ""


def _lesbar(archiv):
    """Das Archiv ganz gelesen (tar -tf). Die Liste der Eintraege geht nicht ins
    Protokoll -- Nextclouds Binddaten allein sind 340 633 Zeilen."""
    try:
        return os.path.isfile(archiv) and subprocess.run(
            ["tar", "-tf", archiv], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=SICHERUNG_TIMEOUT).returncode == 0
    except (subprocess.SubprocessError, OSError):
        return False


def _archiv_schreiben(eintrag, ordner, text):
    """Ein Datentraeger oder eine Bindung als tar in den Ordner, danach ganz
    zurueckgelesen. Das Archiv traegt den letzten Namen des Ortes als Wurzel
    (_data, volumes, ...), zurueckgespielt wird es in dessen Elternordner."""
    ziel = os.path.join(ordner, eintrag["archiv"])
    ort = eintrag["ort"]
    code = _lauf(text, ["tar", "--numeric-owner", "-cpf", ziel, "-C", os.path.dirname(ort),
                        os.path.basename(ort)], "/", SICHERUNG_TIMEOUT)
    # tar: 1 = eine Datei aenderte sich waehrend des Lesens -- die Dienste stehen,
    # also schreibt nur ein anderer, der denselben Ort teilt. Das Archiv ist ganz.
    if code < 0 or code > 1:
        raise _Abbruch("Das Archiv von %s liess sich nicht schreiben (tar exit %s)." % (ort, code))
    if code == 1:
        text.append("  WARNUNG: waehrend des Lesens hat sich eine Datei in %s geaendert -- "
                    "ein anderer Dienst teilt diesen Ort." % ort)
    if not _lesbar(ziel):
        raise _Abbruch("Das Archiv %s liess sich nicht zuruecklesen." % ziel)
    text.append("  gesichert und zurueckgelesen: %s -> %s (%d MB)" % (
        eintrag["quelle"], eintrag["archiv"], os.path.getsize(ziel) // 1048576))


def _ordner_leeren(ort):
    """Den Inhalt eines Ortes entfernen, nicht den Ort selbst (ein Datentraeger oder
    eine Bindung bleibt eingehaengt). Nur gerufen, nachdem der Stand gesichert ist."""
    for kind in os.listdir(ort):
        pfad = os.path.join(ort, kind)
        if os.path.isdir(pfad) and not os.path.islink(pfad):
            shutil.rmtree(pfad)
        else:
            os.remove(pfad)


def _archiv_zurueck(eintrag, ordner, text):
    ort = eintrag["ort"]
    if os.path.isdir(ort) and not os.path.islink(ort):
        _ordner_leeren(ort)
    if _lauf(text, ["tar", "--numeric-owner", "-xpf", os.path.join(ordner, eintrag["archiv"]),
                    "-C", os.path.dirname(ort)], "/", SICHERUNG_TIMEOUT) != 0:
        raise _Abbruch("Das Archiv %s liess sich nicht nach %s zurueckspielen." % (eintrag["archiv"], ort))
    text.append("  zurueckgespielt: %s -> %s" % (eintrag["archiv"], eintrag["quelle"]))


def _manifest_schreiben(ordner, manifest):
    pfad = os.path.join(ordner, "manifest.json")
    with open(pfad + ".part", "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    os.replace(pfad + ".part", pfad)


def _rueckweg_anlegen(job_id, key, compose_file, verzeichnis, projekt, dienste, geaendert,
                      alt, vorher, text):
    """(ordner, grund) -- die Daten der geaenderten Dienste, bei angehaltenen
    Diensten gelesen, und die alten Abbilder unter festen Namen. Scheitert etwas,
    laufen die Dienste wieder auf dem alten Stand, und der halbe Ordner geht weg."""
    liste, grund = _zu_sichern(dienste, geaendert, text)
    if grund:
        return None, grund
    wurzel = os.path.join(RUECKWEG_WURZEL, key, RUECKWEG_BLATT)
    os.makedirs(wurzel, mode=0o750, exist_ok=True)
    grund = _platz_pruefen(liste, wurzel)
    if grund:
        return None, grund
    ordner = os.path.join(wurzel, "%s-auftrag%d" % (datetime.now().strftime("%Y%m%d-%H%M%S"), int(job_id)))
    os.makedirs(ordner, mode=0o750)
    if _lauf(text, ["docker", "compose", "-f", compose_file, "stop"] + geaendert, verzeichnis, 600) != 0:
        shutil.rmtree(ordner)
        _lauf(text, ["docker", "compose", "-f", compose_file, "start"] + geaendert, verzeichnis, 600)
        return None, "Die Dienste liessen sich nicht anhalten -- nichts gesichert, nichts geaendert."
    namen = {}
    # nur die Namen der geaenderten Dienste -- ein Dienst, dessen Abbild bleibt, braucht keinen Rueckweg
    vorher = {ref: k for ref, k in vorher.items() if any(dienste[d]["ref"] == ref for d in geaendert)}
    try:
        for e in liste:
            _archiv_schreiben(e, ordner, text)
        alte = sorted({x for x in list(vorher.values()) + [(alt.get(d) or {}).get("abbild") for d in geaendert] if x})
        for i, kennung in enumerate(alte):
            name = "%s:%s-a%d-%d" % (RUECKWEG_NAME, key, int(job_id), i + 1)
            if _lauf(text, ["docker", "tag", kennung, name], "/", 60) != 0:
                raise _Abbruch("Das alte Abbild %s liess sich nicht festhalten." % kennung)
            namen[kennung] = name
        _manifest_schreiben(ordner, {
            "auftrag": int(job_id), "key": key, "projekt": projekt, "compose_file": compose_file,
            "verzeichnis": verzeichnis, "geaendert": geaendert,
            "dienste": {d: {"ref": dienste[d]["ref"], "alt": (alt.get(d) or {}).get("abbild") or ""}
                        for d in geaendert},
            "namen_vorher": vorher, "namen": namen, "sicherungen": liste})
    except (_Abbruch, OSError) as exc:
        text.append("ABBRUCH: %s" % exc)
        _lauf(text, ["docker", "compose", "-f", compose_file, "start"] + geaendert, verzeichnis, 600)
        for name in namen.values():
            _lauf(text, ["docker", "image", "rm", name], "/", 60)
        shutil.rmtree(ordner)
        return None, "Der Rueckweg liess sich nicht anlegen (%s) -- die Dienste laufen auf dem alten Stand." % exc
    text.append("Rueckweg angelegt: %s" % ordner)
    return ordner, ""


def _gesundheit_warten(projekt, dienste_liste, text):
    """(gut, stand) -- wartet bis GESUNDHEIT_SEKUNDEN, bis jeder genannte Dienst
    laeuft und, wo er eine Gesundheitspruefung hat, healthy meldet. Endet einer
    oder meldet unhealthy, ist das die Antwort -- sofort."""
    frist = time.monotonic() + GESUNDHEIT_SEKUNDEN
    while True:
        stand, grund = _container_stand(projekt)
        if grund:
            text.append("Zustand nicht lesbar: %s" % grund)
            return False, {}
        jetzt = {d: "%s%s" % ((stand.get(d) or {}).get("zustand") or "fehlt",
                              ("/" + stand[d]["gesundheit"]) if (stand.get(d) or {}).get("gesundheit") else "")
                 for d in dienste_liste}
        schlecht = [d for d in dienste_liste if (stand.get(d) or {}).get("zustand") in ("exited", "dead")
                    or (stand.get(d) or {}).get("gesundheit") == "unhealthy"]
        gut = all((stand.get(d) or {}).get("zustand") == "running"
                  and (stand.get(d) or {}).get("gesundheit") in ("", "healthy") for d in dienste_liste)
        if gut or schlecht or time.monotonic() >= frist:
            text.append("Zustand: %s" % ", ".join("%s %s" % (d, jetzt[d]) for d in dienste_liste))
            return gut, jetzt
        time.sleep(5)


def _alte_rueckwege_raeumen(key, text):
    """Nach einem gelungenen Update: die aelteren Rueckwege dieses Dienstes weg,
    RUECKWEG_BEHALTEN bleiben -- samt den Namen, die ihre Abbilder festhalten."""
    wurzel = os.path.join(RUECKWEG_WURZEL, key, RUECKWEG_BLATT)
    ordner = sorted(d for d in os.listdir(wurzel) if RUECKWEG_ORDNER.match(d))
    for alt in ordner[:-RUECKWEG_BEHALTEN]:
        pfad = os.path.join(wurzel, alt)
        try:
            with open(os.path.join(pfad, "manifest.json"), encoding="utf-8") as f:
                namen = (json.load(f).get("namen") or {}).values()
        except (OSError, ValueError):
            namen = []
        for name in namen:
            _lauf(text, ["docker", "image", "rm", name], "/", 60)
        shutil.rmtree(pfad)
        text.append("Aelterer Rueckweg entfernt: %s" % pfad)


def fuehre_update_aus(job_id, key, service_dir, compose_file):
    """(text, code, ergebnis) -- holen, vergleichen, Lizenz, Rueckweg, starten.
    Die Reihenfolge und ihr Warum stehen im Kopf dieser Datei (UPDATE MIT
    LIZENZPRUEFUNG UND RUECKWEG)."""
    text = []
    verzeichnis = _verzeichnis(service_dir)
    daten, grund = compose_config(compose_file, verzeichnis)
    if grund:
        return grund, 1, None
    dienste = _dienste(daten)
    projekt = daten.get("name") or ""
    alt, grund = _container_stand(projekt)
    if grund:
        return grund, 1, None
    refs = sorted({e["ref"] for e in dienste.values()})
    vorher = {ref: (_abbild(ref) or {}).get("Id") for ref in refs}
    ergebnis = {"art": "update", "projekt": projekt, "dienste": {}, "lizenzen": []}
    if any(e["baut"] for e in dienste.values()):
        text.append("Die Compose-Datei hat einen build-Abschnitt: das Abbild wird auf diesem\n"
                    "Server gebaut, nicht aus einer Registry gezogen.")
        code = _lauf(text, ["docker", "compose", "-f", compose_file, "build"], verzeichnis, BAU_TIMEOUT)
    else:
        text.append("Kein build-Abschnitt: das Abbild wird gezogen. Gestartet wird noch nichts.")
        # --quiet: ohne Fortschrittsanzeige -- sie fuellte das Ergebnis von Auftrag #320
        # (terminal, 2026-09-28) mit rund 700 Zeilen je Schicht; Fehler kommen weiter.
        code = _lauf(text, ["docker", "compose", "-f", compose_file, "pull", "--quiet"], verzeichnis,
                     ZIEH_TIMEOUT)
    if code != 0:
        _namen_zurueck(vorher, text)
        return "\n".join(text), code, None
    neu = {ref: (_abbild(ref) or {}).get("Id") for ref in refs}
    geaendert = sorted(d for d, e in dienste.items()
                       if neu.get(e["ref"]) and neu[e["ref"]] != (alt.get(d) or {}).get("abbild"))
    for d, e in sorted(dienste.items()):
        ergebnis["dienste"][d] = {"ref": e["ref"], "alt": (alt.get(d) or {}).get("abbild") or "",
                                  "neu": neu.get(e["ref"]) or "", "geaendert": d in geaendert}
    if not geaendert:
        text.append("Kein Dienst bekommt ein neues Abbild -- nichts gesichert, nichts neu gestartet.")
        return "\n".join(text), 0, ergebnis
    text.append("Neues Abbild fuer: %s" % ", ".join(geaendert))
    angehalten, grund = _lizenzen_pruefen(dienste, geaendert, ergebnis, text)
    if grund or angehalten:
        _namen_zurueck(vorher, text)
        if grund:
            text.append("%s -- nichts geaendert, spaeter erneut versuchen." % grund)
            return "\n".join(text), 1, ergebnis
        ergebnis["halt"] = "lizenz"
        text.append("ANGEHALTEN: eine Lizenz ist neu oder hat sich geaendert. Nichts ist geaendert, "
                    "die Dienste laufen auf dem alten Stand weiter. Unter Result die Lizenz ansehen "
                    "und annehmen -- dann laeuft das Update weiter.")
        return "\n".join(text), EXIT_ANGEHALTEN, ergebnis
    ordner, grund = _rueckweg_anlegen(job_id, key, compose_file, verzeichnis, projekt, dienste,
                                      geaendert, alt, vorher, text)
    if grund:
        _namen_zurueck(vorher, text)
        text.append(grund)
        return "\n".join(text), 1, ergebnis
    ergebnis["ruecksicherung"] = ordner
    # --remove-orphans: die Compose-Datei ist, was Update anwendet. Ein Dienst, der
    # dort nicht mehr steht, geht mit -- so verschwand Watchtower (v2039) beim ersten
    # Update von Open WebUI, statt als angehaltener Container nach einem Neustart
    # des Servers wieder anzulaufen (restart: always).
    if _lauf(text, ["docker", "compose", "-f", compose_file, "up", "-d", "--remove-orphans"],
             verzeichnis, 900) != 0:
        text.append("Der neue Stand ist nicht angelaufen. Roll back stellt den alten aus %s wieder her." % ordner)
        return "\n".join(text), 1, ergebnis
    gut, ergebnis["gesundheit"] = _gesundheit_warten(projekt, geaendert, text)
    if not gut:
        text.append("Der neue Stand laeuft nicht sauber. Roll back stellt den alten aus %s wieder her." % ordner)
        return "\n".join(text), 1, ergebnis
    _alte_rueckwege_raeumen(key, text)
    text.append("Update fertig. Der alte Stand liegt in %s; Roll back stellt ihn wieder her." % ordner)
    return "\n".join(text), 0, ergebnis


def _rueckweg_lesen(key, compose_file, verzeichnis, update_job):
    """(ordner, manifest, grund) -- der Rueckweg des genannten Updates, geprueft,
    bevor irgendetwas angefasst wird: passt er zu diesem Dienst, liegt jedes
    Archiv da und laesst sich lesen, zeigt jeder Ort noch dorthin, wo er beim
    Sichern lag, und gibt es jedes alte Abbild noch."""
    wurzel = os.path.join(RUECKWEG_WURZEL, key, RUECKWEG_BLATT)
    treffer = [d for d in (os.listdir(wurzel) if os.path.isdir(wurzel) else [])
               if (RUECKWEG_ORDNER.match(d) or [None, None])[1] == str(update_job)]
    if len(treffer) != 1:
        return None, None, "Zum Update-Auftrag #%s liegt kein Rueckweg unter %s." % (update_job, wurzel)
    ordner = os.path.join(wurzel, treffer[0])
    try:
        with open(os.path.join(ordner, "manifest.json"), encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError) as exc:
        return None, None, "manifest.json in %s nicht lesbar: %s" % (ordner, exc)
    if (manifest.get("key"), manifest.get("compose_file"), manifest.get("verzeichnis")) != (
            key, compose_file, verzeichnis):
        return None, None, "Der Rueckweg in %s gehoert nicht zu diesem Dienst." % ordner
    for e in manifest.get("sicherungen") or []:
        if e["art"] == "bind":
            ok = _bind_zulaessig(e["ort"]) and os.path.realpath(e["quelle"]) == e["ort"]
        else:
            ort, grund = _datentraeger_ort(e["quelle"])
            ok = not grund and ort == e["ort"]
        if not ok:
            return None, None, "%s liegt nicht mehr dort, wo es gesichert wurde (%s)." % (e["quelle"], e["ort"])
        archiv = os.path.join(ordner, e["archiv"])
        if not _lesbar(archiv):
            return None, None, "Das Archiv %s fehlt oder ist nicht lesbar." % archiv
    for kennung, name in (manifest.get("namen") or {}).items():
        if (_abbild(name) or {}).get("Id") != kennung:
            return None, None, "Das alte Abbild %s (%s) gibt es nicht mehr." % (name, kennung[:19])
    return ordner, manifest, ""


def fuehre_rueckweg_aus(job_id, key, service_dir, compose_file, params_text):
    """(text, code, ergebnis) -- den Stand vor einem Update wiederherstellen. Der
    Stand, den das ersetzt, wird vorher im selben Ordner festgehalten."""
    try:
        werte = json.loads(params_text or "{}") or {}
    except ValueError:
        return "Die Werte des Auftrags sind kein JSON.", 1, None
    update_job = werte.get("update_job")
    if not isinstance(update_job, int) or update_job <= 0:
        return "Der Auftrag nennt kein Update (params.update_job).", 1, None
    text = []
    verzeichnis = _verzeichnis(service_dir)
    ordner, manifest, grund = _rueckweg_lesen(key, compose_file, verzeichnis, update_job)
    if grund:
        return grund + " Nichts geaendert.", 1, None
    geaendert = manifest["geaendert"]
    liste = manifest.get("sicherungen") or []
    jetzt = os.path.join(ordner, "vor-rueckweg-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    grund = _platz_pruefen(liste, ordner)
    if grund:
        return grund, 1, None
    os.makedirs(jetzt, mode=0o750)
    ergebnis = {"art": "rueckweg", "update_job": update_job, "ordner": ordner, "jetzt": jetzt}
    if _lauf(text, ["docker", "compose", "-f", compose_file, "stop"] + geaendert, verzeichnis, 600) != 0:
        _lauf(text, ["docker", "compose", "-f", compose_file, "start"] + geaendert, verzeichnis, 600)
        return "\n".join(text + ["Die Dienste liessen sich nicht anhalten -- nichts geaendert."]), 1, ergebnis
    try:
        for e in liste:
            _archiv_schreiben(e, jetzt, text)
    except (_Abbruch, OSError) as exc:
        _lauf(text, ["docker", "compose", "-f", compose_file, "start"] + geaendert, verzeichnis, 600)
        return "\n".join(text + ["ABBRUCH: %s -- nichts geaendert." % exc]), 1, ergebnis
    text.append("Der Stand nach dem Update liegt in %s." % jetzt)
    try:
        for e in liste:
            _archiv_zurueck(e, ordner, text)
    except (_Abbruch, OSError) as exc:
        text.append("ABBRUCH beim Zurueckspielen: %s. Die Dienste bleiben angehalten; der Stand "
                    "nach dem Update liegt vollstaendig in %s." % (exc, jetzt))
        return "\n".join(text), 1, ergebnis
    for ref, kennung in sorted((manifest.get("namen_vorher") or {}).items()):
        if kennung and _lauf(text, ["docker", "tag", kennung, ref], "/", 60) != 0:
            text.append("Der Name %s liess sich nicht auf den alten Stand setzen." % ref)
            return "\n".join(text), 1, ergebnis
    if _lauf(text, ["docker", "compose", "-f", compose_file, "up", "-d"], verzeichnis, 900) != 0:
        return "\n".join(text), 1, ergebnis
    gut, ergebnis["gesundheit"] = _gesundheit_warten(manifest.get("projekt") or "", geaendert, text)
    abweichend = sorted(d for d, e in (manifest.get("dienste") or {}).items()
                        if e.get("alt") and e["alt"] != (manifest.get("namen_vorher") or {}).get(e.get("ref")))
    if abweichend:
        text.append("HINWEIS: %s lief vor dem Update auf einem noch aelteren Stand als dem, auf den "
                    "sein Name zeigte; zurueckgesetzt ist er auf den Stand des Namens." % ", ".join(abweichend))
    text.append("Rueckweg %s." % ("fertig" if gut else "gelaufen, aber nicht jeder Dienst laeuft sauber"))
    return "\n".join(text), 0 if gut else 1, ergebnis


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


def pruefe_probeskript(setup_script):
    """(Datei, Grund) -- wie pruefe_aufbauskript, dazu der SCHUTZ des Probelaufs:
    das Skript muss die Zeichenfolge PROBE_MARKE tragen. Sonst wuerde es den
    Umgebungswert ueberlesen und den vollen Aufbau fahren -- benannt, nicht
    ausgefuehrt (R-NO-SILENT-FALLBACK-01)."""
    datei, grund = pruefe_aufbauskript(setup_script)
    if grund:
        return "", grund
    try:
        with open(datei, encoding="utf-8", errors="replace") as f:
            kennt = PROBE_MARKE in f.read()
    except OSError as exc:
        return "", "Aufbauskript nicht lesbar: %s (%s)" % (datei, exc)
    if not kennt:
        return "", ("%s kennt keinen Probelauf (die Zeichenfolge %s steht nicht darin) -- "
                    "er wuerde den vollen Aufbau fahren und laeuft deshalb nicht." % (datei, PROBE_MARKE))
    return datei, ""


def fuehre_probe_aus(datei):
    """Das Aufbauskript wie beim Aufbau -- festes argv, sein Verzeichnis, dieselbe
    Frist --, dazu PROBE_MARKE=1 in der Umgebung."""
    text, code = _schritte_ausfuehren([["bash", datei]], AUFBAU_DIR, AUFBAU_TIMEOUT,
                                      umgebung=dict(os.environ, **{PROBE_MARKE: "1"}))
    return "Probelauf: %s=1 gesetzt.\n%s" % (PROBE_MARKE, text), code


def pruefe_modulauftrag(kind, target, skript=MODUL_SKRIPT):
    """(Datei, Grund) -- eine Erweiterung holt (und entfernt) nur der Bestandteil
    Toolserver, und nur mit einem Key in der Form eines Modulschluessels. Alles
    andere wird benannt, nicht ausgefuehrt (R-NO-SILENT-FALLBACK-01)."""
    if kind != TOOLSERVER_KIND:
        return "", "Eine Erweiterung gehoert zum Toolserver, nicht zu einem Bestandteil der Art '%s'." % kind
    key = (target or "").strip()
    if not MODUL_KEY.match(key):
        return "", "Unzulaessiger Modulschluessel '%s' -- erwartet: Kleinbuchstaben, Ziffern, _." % key
    datei = os.path.join(AUFBAU_DIR, skript)
    if not os.path.isfile(datei):
        return "", "%s nicht gefunden -- dieser Server wurde nicht vom Installer eingerichtet." % datei
    return datei, ""


def fuehre_modul_aus(datei, key):
    """setup-module.sh <key> (oder remove-module.sh <key>), festes argv, im
    Verzeichnis der Aufbauskripte."""
    return _schritte_ausfuehren([["bash", datei, key]], AUFBAU_DIR, AUFBAU_TIMEOUT)


def pruefe_hostauftrag(target, params_text):
    """(Datei, Umgebung, Grund) -- die Arbeit muss in HOST_ARBEITEN stehen, ihre Werte
    die Form haben, die der Toolserver schon geprueft hat. Alles andere wird benannt,
    nicht ausgefuehrt (R-NO-SILENT-FALLBACK-01)."""
    arbeit = (target or "").strip()
    if arbeit not in HOST_ARBEITEN:
        return "", None, "Unbekannte Arbeit am Server '%s'." % arbeit
    try:
        werte = json.loads(params_text or "{}") or {}
    except ValueError:
        return "", None, "Die Werte der Arbeit sind kein JSON."
    umgebung = {}
    for feld in HOST_ARBEITEN[arbeit]:
        wert = str(werte.get(feld) or "").strip()
        if feld == "user" and (not HOST_BENUTZER.match(wert) or wert in ("root", "manager")):
            return "", None, "Unzulaessiger Benutzername '%s'." % wert
        if feld == "key" and not HOST_SCHLUESSEL.match(wert):
            return "", None, "Das ist kein oeffentlicher SSH-Schluessel."
        umgebung["HT_" + feld.upper()] = wert
    datei = os.path.join(AUFBAU_DIR, HOST_SKRIPT)
    if not os.path.isfile(datei):
        return "", None, "%s nicht gefunden -- dieser Server wurde nicht vom Installer eingerichtet." % datei
    return datei, umgebung, ""


def _relay_zugang():
    """(json_text, grund) -- der SMTP-Zugang aus dem Toolserver, fuer harden_mail. Das
    Ergebnis traegt das Kennwort und geht NUR auf stdin von host-task.sh."""
    try:
        r = subprocess.run(["docker", "exec", "-w", "/app", "toolserver", "python", "-m",
                            "services.svc_hostaufgaben", "relay"],
                           capture_output=True, text=True, timeout=60)
    except Exception as exc:  # noqa: BLE001 -- der Auftrag endet sichtbar als failed
        return "", "Der SMTP-Zugang liess sich nicht aus dem Toolserver holen: %s" % exc
    zeilen = r.stdout.strip().splitlines()
    try:
        d = json.loads(zeilen[-1]) if zeilen else {}
    except ValueError:
        d = {}
    if r.returncode != 0 or not d or d.get("error"):
        return "", ("Der Toolserver nennt keinen SMTP-Zugang: %s"
                    % (d.get("error") or (r.stderr or r.stdout).strip()[-400:]))
    return zeilen[-1], ""


def fuehre_hostarbeit_aus(datei, arbeit, umgebung):
    """host-task.sh <arbeit>, festes argv, die Werte in der Umgebung; fuer harden_mail
    der SMTP-Zugang auf stdin (nie im Protokoll)."""
    eingabe = ""
    if arbeit == "harden_mail":
        eingabe, grund = _relay_zugang()
        if grund:
            return grund, 1
    env = dict(os.environ)
    env.update(umgebung)
    text = ["$ bash %s %s   (in %s)" % (datei, arbeit, AUFBAU_DIR)]
    try:
        r = subprocess.run(["bash", datei, arbeit], cwd=AUFBAU_DIR, input=eingabe, env=env,
                           capture_output=True, text=True, timeout=HOST_TIMEOUT)
    except Exception as exc:  # noqa: BLE001 -- der Auftrag endet sichtbar als failed
        text.append("Exception: %s" % exc)
        return "\n".join(text), 1
    text.append(r.stdout)
    if r.stderr:
        text.append(r.stderr)
    text.append("exit %s" % r.returncode)
    return "\n".join(text), r.returncode


def bearbeite(auftrag):
    global _laufender_auftrag
    (job_id, component_key, action, service_dir, compose_file, kind,
     backup_script, setup_script, target, params_text) = auftrag
    log("Auftrag #%s: %s / %s%s" % (job_id, component_key, action, (" " + target) if target else ""))
    markiere_laufend(job_id)
    if action == "update":
        if not compose_file or not service_dir:
            schliesse_ab(job_id, "failed",
                         "Kein Verzeichnis oder keine Compose-Datei fuer '%s' hinterlegt." % component_key, None)
            return
        lauf = lambda: fuehre_update_aus(job_id, component_key, service_dir, compose_file)  # noqa: E731
    elif action == "rollback":
        if kind == TOOLSERVER_KIND or not compose_file or not service_dir:
            schliesse_ab(job_id, "failed",
                         "Ein Rueckweg gehoert zu einem Dienst mit Verzeichnis und Compose-Datei -- "
                         "der Toolserver hat seinen eigenen (Rueckweg-Patch und Release-Marke).", None)
            return
        lauf = lambda: fuehre_rueckweg_aus(job_id, component_key, service_dir, compose_file,  # noqa: E731
                                           params_text)
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
    elif action == "probe":
        datei, grund = pruefe_probeskript(setup_script)
        if grund:
            schliesse_ab(job_id, "failed", grund, None)
            return
        lauf = lambda: fuehre_probe_aus(datei)  # noqa: E731
    elif action == "module":
        datei, grund = pruefe_modulauftrag(kind, target)
        if grund:
            schliesse_ab(job_id, "failed", grund, None)
            return
        lauf = lambda: fuehre_modul_aus(datei, target.strip())  # noqa: E731
    elif action == "module_remove":
        datei, grund = pruefe_modulauftrag(kind, target, MODUL_ENTFERNEN_SKRIPT)
        if grund:
            schliesse_ab(job_id, "failed", grund, None)
            return
        lauf = lambda: fuehre_modul_aus(datei, target.strip())  # noqa: E731
    elif action == "host":
        datei, umgebung, grund = pruefe_hostauftrag(target, params_text)
        if grund:
            schliesse_ab(job_id, "failed", grund, None)
            return
        lauf = lambda: fuehre_hostarbeit_aus(datei, target.strip(), umgebung)  # noqa: E731
    else:
        schliesse_ab(job_id, "failed",
                     "Unbekannte Aktion '%s' -- v14 kennt 'update', 'rollback', 'restart', 'backup', "
                     "'setup', 'probe', 'module', 'module_remove' und 'host'." % action, None)
        return
    _laufender_auftrag = job_id
    try:
        antwort = lauf()
    except Exception:  # noqa: BLE001 -- der Auftrag endet sichtbar, der Dienst laeuft weiter
        schliesse_ab(job_id, "failed", "Unerwarteter Fehler:\n%s" % traceback.format_exc(), None)
        return
    finally:
        _laufender_auftrag = None
    text, code = antwort[0], antwort[1]
    ergebnis = antwort[2] if len(antwort) > 2 else None
    # held (v14): ein Update wartet auf die Annahme einer Lizenz -- beendet, nichts geaendert.
    status = ("held" if code == EXIT_ANGEHALTEN and ergebnis and ergebnis.get("halt")
              else ("ok" if code == 0 else "failed"))
    schliesse_ab(job_id, status, text, code, ergebnis)
    log("Auftrag #%s beendet: %s" % (job_id, status))


def eigene_datei_geaendert(stand):
    try:
        return os.stat(EIGENE_DATEI).st_mtime != stand
    except OSError:
        return False


def main():
    stand = os.stat(EIGENE_DATEI).st_mtime
    log("verwalter.py v14 gestartet, Abfrage alle %ss" % POLL_SECONDS)
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
