#!/usr/bin/env bash
# update-dev-stack.sh
# Update-/Restart-Flow für groupware, opencloud (dev-docker), docker compose (web)
# und imap-filler – in genau der angegebenen Reihenfolge.
#
# Stand: berücksichtigt die Stalwart-0.16-/Backend-Umstellung (web#2714).
# Wichtige Punkte, die in dieser Variante adressiert sind:
#   - stalwart-import (One-shot Init-Job) wird mitgestartet und korrekt abgewartet
#   - tika-service ist ebenfalls ein One-shot-Job (wait-for-dependencies), kein Langläufer
#   - Der Demo-Principal-Import läuft NICHT mehr über das veraltete stalwart-admin-Tool,
#     sondern über stalwart-import (stalwart-cli apply)
#   - web-Repo wird NICHT automatisch gepullt (lokale #2714-Fixes bleiben erhalten)
#
# Voraussetzung in der web/docker-compose.yml (lokal, bis upstream gemerged):
#   command: ["mkdir -p /var/lib/opencloud/idm && (opencloud init || true) && opencloud server"]
#   (legt das idm-Verzeichnis an -> nötig für opencloud-rolling:daily; schadet dev-Image nicht)

set -Eeuo pipefail

# ---------------------- Konfiguration ----------------------
GROUPWARE_DIR="/Users/t.thamm/gitrepos/groupware/opencloud"
OPENCLOUD_DIR="$GROUPWARE_DIR/opencloud"
WEB_DIR="/Users/t.thamm/gitrepos/web"
IMAP_FILLER_DIR="/Users/t.thamm/gitrepos/imap-filler"

# Langläufer-Services, auf deren Healthcheck/Running wir warten (Reihenfolge wie gewünscht)
WEB_SERVICES=(traefik opencloud stalwart radicale)

# One-shot Init-Jobs: starten, laufen einmal durch, beenden sich (Exit 0).
# - tika-service (dadarek/wait-for-dependencies): wartet auf tika:9998 und beendet sich.
# - stalwart-import: wartet auf die Stalwart-Recovery-API, spielt die Konfiguration
#   inkl. Demo-Principals per stalwart-cli ein und legt /var/lib/stalwart/.initialized an.
# WICHTIG: NICHT in WEB_SERVICES, sonst läuft wait_for_services in den Timeout,
# sobald der Job bereits beendet ist (ps -q findet beendete Container nicht).
WEB_INIT_SERVICES=(tika-service stalwart-import)

# IMAP-Filler Parameter
IMAP_USER="alan"
IMAP_PASS="demo"
IMAP_FOLDER="Inbox"
IMAP_SENDERS="6"
IMAP_COUNT="50"

# Timeout fürs Warten auf Container (Sekunden)
WAIT_TIMEOUT=240
WAIT_INTERVAL=2

# ---------------------- Helfer ----------------------
now() { date "+%F %T"; }
log() { printf "[%s] %s\n" "$(now)" "$*"; }
fail() { log "❌ $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Benötigtes Kommando nicht gefunden: $1"; }
need_dir() { [[ -d "$1" ]] || fail "Benötigtes Verzeichnis fehlt: $1"; }
run() {
  log "▶ $*"
  local _start _end
  _start=$(date +%s)
  "$@"
  _end=$(date +%s)
  log "✓ Fertig in $((_end - _start))s"
}

# Prüft Status eines Containers: bevorzugt Healthcheck, sonst Running
container_ready() {
  local cid="$1"
  local health
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null || true)
  if [[ -n "${health:-}" ]]; then
    [[ "$health" == "healthy" ]] && return 0
    [[ "$health" == "unhealthy" ]] && return 2
    return 1
  else
    local running
    running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)
    [[ "$running" == "true" ]] && return 0 || return 1
  fi
}

wait_for_container() {
  local cid="$1" name="$2"
  local elapsed=0
  while true; do
    if container_ready "$cid"; then
      log "✅ Container '$name' bereit (CID: ${cid:0:12})."
      return 0
    fi
    local st=$?
    if [[ $st -eq 2 ]]; then
      fail "Container '$name' ist UNHEALTHY (CID: ${cid:0:12})."
    fi
    if (( elapsed >= WAIT_TIMEOUT )); then
      docker inspect "$cid" >/dev/null 2>&1 && \
        log "ℹ️  Diagnose (Status): $(docker inspect -f '{{json .State}}' "$cid")"
      fail "Timeout: Container '$name' wurde nicht rechtzeitig bereit."
    fi
    sleep "$WAIT_INTERVAL"
    (( elapsed += WAIT_INTERVAL ))
  done
}

wait_for_services() {
  local services=("$@")
  for svc in "${services[@]}"; do
    local cid
    cid=$(docker compose ps -q "$svc")
    [[ -z "$cid" ]] && fail "Kein Container für Service '$svc' gefunden. Ist der Service-Name korrekt?"
    wait_for_container "$cid" "$svc"
  done
}

# Wartet, bis ein One-shot Init-Job durchgelaufen ist, und prüft seinen Exit-Code.
# Nutzt 'ps -aq' (inkl. beendeter Container), damit ein schon beendeter Job gefunden wird.
wait_for_init_job() {
  local svc="$1"
  local cid
  cid=$(docker compose ps -aq "$svc")
  [[ -z "$cid" ]] && fail "Kein Container für Init-Job '$svc' gefunden. Ist der Service-Name korrekt?"
  local elapsed=0 status exitcode running
  while true; do
    running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)
    status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)
    if [[ "$running" != "true" && "$status" == "exited" ]]; then
      exitcode=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo 1)
      if [[ "$exitcode" == "0" ]]; then
        log "✅ Init-Job '$svc' erfolgreich abgeschlossen."
        return 0
      fi
      log "ℹ️  Logs von '$svc':"
      docker compose logs "$svc" --tail=50 || true
      fail "Init-Job '$svc' mit Exit-Code $exitcode fehlgeschlagen."
    fi
    if (( elapsed >= WAIT_TIMEOUT )); then
      docker compose logs "$svc" --tail=50 || true
      fail "Timeout: Init-Job '$svc' wurde nicht rechtzeitig fertig."
    fi
    sleep "$WAIT_INTERVAL"
    (( elapsed += WAIT_INTERVAL ))
  done
}

trap 'log "❌ Fehler in Zeile $LINENO bei: $BASH_COMMAND"' ERR

# ---------------------- Voraussetzungen prüfen ----------------------
need_cmd git
need_cmd make
need_cmd docker
need_cmd go
run docker compose version >/dev/null

need_dir "$GROUPWARE_DIR"
need_dir "$OPENCLOUD_DIR"
need_dir "$WEB_DIR"
need_dir "$IMAP_FILLER_DIR"

# ---------------------- Ablauf ----------------------
# groupware aktualisieren
run cd "$GROUPWARE_DIR"
run git fetch origin
# ⚠️ Verwirft lokale Änderungen wie gewünscht:
run git reset --hard origin/groupware
run make generate

# opencloud dev-docker bauen/starten
# Hinweis: Der opencloud-Build verlangt seit der 0.16-Umstellung Go 1.26 (go.mod),
# das Build-Image quay.io/opencloudeu/golang-ci:1.25 bringt aber nur Go 1.25.
# Falls 'make dev-docker' an 'requires go >= 1.26.0' scheitert: Build-Image im
# groupware-Repo ist noch nicht auf 1.26 gehoben -> Team. Lokaler Notnagel:
# im opencloud/docker/Dockerfile.multiarch der Build-RUN-Zeile 'GOTOOLCHAIN=auto'
# voranstellen, damit Go die 1.26-Toolchain im Container selbst nachlädt.
run cd "$OPENCLOUD_DIR"
run make dev-docker

# web stack neu starten
# Hinweis: web-Repo wird bewusst NICHT automatisch gepullt – lokale #2714-bezogene
# Anpassungen (mkdir-Init, GROUPWARE_JMAP_MASTER_USERNAME=admin@example.org,
# GRAPH_LDAP_BIND_PASSWORD=some-ldap-idm-password) sollen erhalten bleiben.
run cd "$WEB_DIR"
# Volumes werden absichtlich gelöscht (-v); OpenCloud-Config/Daten und Stalwart
# starten danach frisch. --remove-orphans räumt evtl. übrig gebliebene Container ab.
run docker compose down -v --remove-orphans
# Langläufer + One-shot Init-Jobs zusammen starten.
run docker compose up -d "${WEB_SERVICES[@]}" "${WEB_INIT_SERVICES[@]}"

# Auf Langläufer warten (Healthchecks oder Running)
log "⏳ Warte auf Services: ${WEB_SERVICES[*]}"
wait_for_services "${WEB_SERVICES[@]}"

# Auf die One-shot Init-Jobs warten:
# - tika-service stellt sicher, dass Tika erreichbar ist (verhindert den search-FTL).
# - stalwart-import spielt die Konfiguration inkl. Demo-Principals ein und holt
#   Stalwart aus dem Recovery Mode. Erst danach lassen sich Mailboxen füllen.
log "⏳ Warte auf Init-Jobs: ${WEB_INIT_SERVICES[*]}"
for job in "${WEB_INIT_SERVICES[@]}"; do
  wait_for_init_job "$job"
done

# Hinweis: Der frühere Schritt
#   (cd stalwart-admin && go run . principal import --activate ...)
# entfällt. Das stalwart-admin-Tool spricht die alte Stalwart-API (/api/principal) an,
# die es in 0.16.8 nicht mehr gibt (-> /api/account). Der Demo-Principal-Import wird
# seit web#2714 vom Init-Job 'stalwart-import' per 'stalwart-cli apply' übernommen.

# imap-filler ausführen
run cd "$IMAP_FILLER_DIR"
run git pull
run go run . \
  --username="$IMAP_USER" \
  --password="$IMAP_PASS" \
  --empty=false \
  --folder="$IMAP_FOLDER" \
  --senders="$IMAP_SENDERS" \
  --count="$IMAP_COUNT"
run go run . --username=alan --password=demo --count=50 --senders=6 --jmap-account=f --jmap=true || true
run go run . --username=alan --password=demo --count=50 --senders=6 --jmap-account=g --jmap=true || true
run go run . --username=alan --password=demo --count=20 --senders=2 --mailbox-role=drafts

log "🎉 Alles erledigt."
