#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# setup-docserver.sh -- document processing stack of the Toolserver
# Contains: Docling (text from PDF, DOCX, XLSX, PPTX, HTML), Gotenberg (HTML/Office -> PDF),
#           PaddleOCR (CPU OCR for scans and images, built on this host)
# Network:  traefik_web, internal only -- no Traefik route, no public name
# Reached by the Toolserver by container name: docling:5001 | gotenberg:3000 | paddleocr:8868
#           (docker-compose.toolserver.yml: DOCLING_URL, DOCSERVER_GOTENBERG_URL)
#
# Call:  sudo /opt/<domain>/setup-docserver.sh   (the domain is this directory's name)
#
# 2026-09-27 (GAP-ENV-KUNDE-WEITERE-DIENSTE-01): taken over from the setup script of the
# Onions server into the installer. Without it a new host had no Docling, and Knowledge
# read text formats only -- no PDF, no Office file. Operator 2026-09-25: "alle uebrigen
# container die wir brauchen fuer den Vollbetrieb bereits waehrend der
# terminalinstallation" -- step 7 runs it after Weaviate and Nextcloud; the Verwalter runs
# it again from Environment > Installation (job "setup").
# Changed against the original:
#   1. A re-run no longer tears the stack down ("docker compose down" + deleting the compose
#      file) and no longer deletes the PaddleOCR image: the compose file is backed up and
#      rewritten, "up -d" recreates what changed, the image is rebuilt from the build cache.
#   2. No "usermod -aG docker ${SUDO_USER:-chris}": group membership is the installer's
#      business (step 3); here it is only done for a SUDO_USER that exists.
#   3. The catalogue of the Toolserver marks the docserver installed (toolserver-link.sh),
#      and sichern.sh is written (sicherung.sh): the settings and the compose file; the
#      model caches are left out, they are downloaded again.
#   4. Texts in English, like the whole installer.
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DOMAIN="$(basename "$SCRIPT_DIR")"
readonly BASE_DIR="/opt/docserver"
readonly COMPOSE_FILE="${BASE_DIR}/docker-compose.docserver.yml"
readonly CREDENTIALS_DIR="${BASE_DIR}/credentials"
readonly VOLUMES_DIR="${BASE_DIR}/volumes"
readonly PADDLE_IMAGE="paddleocr-local:1.1"

INFO_COLOR='\033[1;36m'
SUCCESS_COLOR='\033[1;32m'
WARN_COLOR='\033[1;33m'
ERROR_COLOR='\033[1;31m'
NC='\033[0m'

log_info()    { echo -e "${INFO_COLOR}[INFO]${NC} $1"; }
log_success() { echo -e "${SUCCESS_COLOR}[OK]${NC} $1"; }
log_warn()    { echo -e "${WARN_COLOR}[WARN]${NC} $1"; }
log_error()   { echo -e "${ERROR_COLOR}[ERROR]${NC} $1"; }

# shellcheck source=toolserver-link.sh
if [[ -f "${SCRIPT_DIR}/toolserver-link.sh" ]]; then
    . "${SCRIPT_DIR}/toolserver-link.sh"
else
    ts_catalogue_installed() { log_warn "toolserver-link.sh missing in ${SCRIPT_DIR} -- catalogue not updated."; }
fi

check_prerequisites() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must run as root (sudo)."
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        log_error "The docker compose plugin is missing."
        exit 1
    fi
    if ! docker network ls --format '{{.Name}}' | grep -qx traefik_web; then
        log_error "Docker network 'traefik_web' not found -- Traefik comes first."
        exit 1
    fi
    log_success "Prerequisites met."
}

create_dirs() {
    mkdir -p "${VOLUMES_DIR}"/{paddleocr-models,docling-models,gotenberg-fonts}
    mkdir -p "${CREDENTIALS_DIR}"
    chown -R 1000:1000 "${VOLUMES_DIR}"
    log_success "Directory structure present."
}

backup_compose() {
    if [[ -f "$COMPOSE_FILE" ]]; then
        local stamp
        stamp="$(date '+%Y%m%d-%H%M%S')"
        cp -p "$COMPOSE_FILE" "${COMPOSE_FILE}.${stamp}.bak"
        log_success "Previous compose file kept: $(basename "$COMPOSE_FILE").${stamp}.bak"
    fi
}

# PaddleOCR: a small Flask server on paddleocr 2.7.3 (paddlehub's hubserving imports
# paddle.fluid, which paddlepaddle removed in 2.5).
build_paddleocr_image() {
    log_info "Writing the PaddleOCR server ..."
    cat > "${BASE_DIR}/paddleocr_server.py" <<'PYEOF'
"""paddleocr_server.py -- Flask OCR server of the docserver stack.
API: POST /predict/ocr_system  { "images": ["<base64_png>"] }
     GET  /                    -> 200 OK (health check)
Response: { "results": [[{"text":"..","confidence":0.9,"text_region":[[x,y],..]},...]], "status":"000" }
"""
import base64
import io
import logging
import numpy as np
from flask import Flask, request, jsonify
from PIL import Image
from paddleocr import PaddleOCR

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger(__name__)

app = Flask(__name__)

logger.info("Initializing PaddleOCR (lang=latin, use_gpu=False)...")
_ocr = PaddleOCR(use_angle_cls=True, lang='latin', use_gpu=False, show_log=False)
logger.info("PaddleOCR ready.")

@app.route('/predict/ocr_system', methods=['POST'])
def predict():
    data    = request.get_json(force=True, silent=True) or {}
    images  = data.get('images', [])
    results = []
    for b64 in images:
        try:
            img    = Image.open(io.BytesIO(base64.b64decode(b64))).convert('RGB')
            res    = _ocr.ocr(np.array(img), cls=True)
            blocks = []
            for line in (res[0] if res else []):
                if not line:
                    continue
                bbox, (text, conf) = line
                blocks.append({
                    'text':        text,
                    'confidence':  float(conf),
                    'text_region': [[int(p[0]), int(p[1])] for p in bbox],
                })
            results.append(blocks)
        except Exception as exc:
            logger.warning("OCR page error: %s", exc)
            results.append([])
    return jsonify({'results': results, 'status': '000'})

@app.route('/', methods=['GET'])
def health():
    return 'OK', 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8868, threaded=False)
PYEOF

    cat > "${BASE_DIR}/Dockerfile.paddleocr" <<'EOF'
# paddleocr-local:1.1 -- Flask server instead of paddlehub hubserving
FROM paddlepaddle/paddle:2.6.1

RUN pip install --no-cache-dir \
    "paddleocr==2.7.3" \
    "flask>=2.0,<3.0" \
    "gunicorn>=21.0" \
    "Pillow>=9.0" \
    "shapely" \
    "pyclipper" \
    "lmdb" \
    "tqdm" \
    "numpy<1.24"

COPY paddleocr_server.py /app/server.py
WORKDIR /app
EXPOSE 8868
HEALTHCHECK --interval=30s --timeout=10s --retries=5 --start-period=120s \
    CMD curl -sf http://localhost:8868/ || exit 1
# 1 worker: the PaddleOCR model is not thread-safe; 300 s for large PDFs
CMD ["gunicorn", "--workers", "1", "--bind", "0.0.0.0:8868", "--timeout", "300", "--access-logfile", "-", "server:app"]
EOF

    log_info "Building ${PADDLE_IMAGE} (the first build takes a while) ..."
    docker build -t "${PADDLE_IMAGE}" -f "${BASE_DIR}/Dockerfile.paddleocr" "${BASE_DIR}"
    log_success "Image ${PADDLE_IMAGE} ready."
}

create_compose() {
    cat > "$COMPOSE_FILE" <<EOF
# Docserver stack -- document processing, internal only (written by setup-docserver.sh)
# Toolserver access: paddleocr:8868 | docling:5001 | gotenberg:3000
services:

  paddleocr:
    image: ${PADDLE_IMAGE}
    container_name: paddleocr
    restart: always
    volumes:
      - paddleocr-models:/root/.paddleocr
    networks: [traefik_web]
    expose: ["8868"]
    labels:
      - "traefik.enable=false"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8868/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

  docling:
    image: quay.io/docling-project/docling-serve-cpu:latest
    container_name: docling
    restart: always
    volumes:
      - docling-models:/opt/app-root/src/.cache/docling
    networks: [traefik_web]
    expose: ["5001"]
    labels:
      - "traefik.enable=false"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:5001/health || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 60s

  gotenberg:
    image: gotenberg/gotenberg:8
    container_name: gotenberg
    restart: always
    networks: [traefik_web]
    expose: ["3000"]
    labels:
      - "traefik.enable=false"
    command:
      - gotenberg
      - --chromium-disable-javascript=true
      - --chromium-allow-list=file:///tmp/.*
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:3000/health || exit 1"]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 20s

networks:
  traefik_web:
    external: true

volumes:
  paddleocr-models: {}
  docling-models: {}
EOF
    sed -i '1s/^\xEF\xBB\xBF//; s/\r$//' "$COMPOSE_FILE"
    chmod 664 "$COMPOSE_FILE"
    log_success "Compose file written."
}

save_endpoints() {
    cat > "${CREDENTIALS_DIR}/docserver-endpoints.txt" <<EOF
Docserver -- internal endpoints
===============================
Reachable only inside the Docker network traefik_web (no public access).

PaddleOCR : http://paddleocr:8868/predict/ocr_system   POST {"images": ["<base64>"]}
Docling   : http://docling:5001   POST /v1/convert/source
Gotenberg : http://gotenberg:3000  POST /forms/chromium/convert/html, /forms/libreoffice/convert

Status: cd ${BASE_DIR} && docker compose -f docker-compose.docserver.yml ps
Written: $(date '+%Y-%m-%d %H:%M')
EOF
    chmod 640 "${CREDENTIALS_DIR}/docserver-endpoints.txt"
}

set_project_permissions() {
    local admin_user="${SUDO_USER:-}"
    chmod -R g+rwX "${BASE_DIR}"
    chmod 770 "${CREDENTIALS_DIR}"
    if [[ -n "$admin_user" && "$admin_user" != root ]] && id "$admin_user" >/dev/null 2>&1; then
        if ! id -nG "$admin_user" | grep -qw docker; then
            usermod -aG docker "$admin_user"
            log_warn "User '${admin_user}' added to the docker group -- log in again."
        fi
    fi
    log_success "Permissions set."
}

start_stack() {
    log_info "Bringing the stack to the state above (docker compose up -d) ..."
    (cd "${BASE_DIR}" && docker compose -f docker-compose.docserver.yml up -d --remove-orphans)

    log_info "Waiting for the health checks (at most 300 s) ..."
    local elapsed=0 docling_ok gotenberg_ok paddle_status
    while (( elapsed < 300 )); do
        sleep 10
        elapsed=$((elapsed + 10))
        docling_ok=$(docker inspect --format='{{.State.Health.Status}}' docling 2>/dev/null || echo "missing")
        gotenberg_ok=$(docker inspect --format='{{.State.Health.Status}}' gotenberg 2>/dev/null || echo "missing")
        paddle_status=$(docker inspect --format='{{.State.Health.Status}}' paddleocr 2>/dev/null || echo "starting")
        log_info "  [${elapsed}s] docling=${docling_ok} | gotenberg=${gotenberg_ok} | paddleocr=${paddle_status}"
        if [[ "$docling_ok" == healthy && "$gotenberg_ok" == healthy ]]; then
            log_success "Docling and Gotenberg ready."
            [[ "$paddle_status" == healthy ]] && log_success "PaddleOCR ready." \
                || log_warn "PaddleOCR not healthy yet (start period 120 s) -- it keeps starting in the background."
            return 0
        fi
    done
    log_error "Docling or Gotenberg did not become healthy within 300 s:"
    (cd "${BASE_DIR}" && docker compose -f docker-compose.docserver.yml ps)
    return 1
}

write_backup_script() {
    if [[ -f "${SCRIPT_DIR}/sicherung.sh" ]]; then
        # shellcheck source=sicherung.sh
        . "${SCRIPT_DIR}/sicherung.sh"
        backup_script_write "$BASE_DIR" "backup_run docserver ${BASE_DIR} /opt/backups/docserver/sicherung --exclude volumes"
    else
        log_warn "sicherung.sh missing in ${SCRIPT_DIR} -- no backup script written."
    fi
}

main() {
    log_info "========================================================"
    log_info " Docserver -- Docling / Gotenberg / PaddleOCR (internal only)"
    log_info " Domain: ${DOMAIN}"
    log_info "========================================================"
    check_prerequisites
    create_dirs
    backup_compose
    build_paddleocr_image
    create_compose
    save_endpoints
    set_project_permissions
    start_stack
    ts_catalogue_installed docserver
    write_backup_script
    log_success "========================================================"
    log_success " Docserver ready. Knowledge reads PDF and Office files from now on."
    log_success "========================================================"
}

main
