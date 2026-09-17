#!/usr/bin/env bash
# steps/20-firewall.sh -- the firewall baseline. Sourced by install.sh.

STEP_20_TITLE="Firewall (deny in, allow 22/80/443, submission out, no direct SMTP)"

step_20_run() {
    heading "$STEP_20_TITLE"
    fw_install
    log_warn "The firewall is enabled at the end of this step. SSH on port 22 stays open."
    fw_baseline
    log_info "Current rules:"
    fw_status | tee -a "$LOG_FILE"
    step_done 20
    log_ok "Firewall baseline active."
}
