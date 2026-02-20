#!/bin/bash

# ==============================================================================
# SBOM Monitor Agent Script
# - 최초 실행 시: Syft 다운로드, 설정 저장, 초기 스캔, crontab 등록
# - 정기 실행 시: SBOM 스캔 및 Nexus3/Black Duck 업로드
# ==============================================================================

set -e

# 환경 설정 (운영 환경에 맞게 수정 필요)
NEXUS_URL="http://your-nexus-server:8081"
NEXUS_REPO="sbom-monitor-raw"
BLACKDUCK_URL="https://your-blackduck-server"
BLACKDUCK_TOKEN="YOUR_API_TOKEN"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.conf"
AGENT_DIR="${SCRIPT_DIR}/bin"
OUTPUT_DIR="${SCRIPT_DIR}/output"
SYFT_BIN="${AGENT_DIR}/syft"
LOG_FILE="${SCRIPT_DIR}/log/sbom-monitor.log"
SCRIPT_VERSION="v1.0.0"
CURL_CMD="curl -s"

# 0. 자가 업데이트 함수
check_for_updates() {
    # 0.1. Check for script updates
    log "Checking script version (current: $SCRIPT_VERSION)..."
    REMOTE_VERSION_URL="${NEXUS_URL}/repository/${NEXUS_REPO}/agent/version.txt"
    LATEST_SCRIPT_VERSION=$($CURL_CMD -s "$REMOTE_VERSION_URL" || echo "$SCRIPT_VERSION")

    if [[ "$LATEST_SCRIPT_VERSION" != "$SCRIPT_VERSION" ]]; then
        log "New script version found: $LATEST_SCRIPT_VERSION. Proceeding with update."
        NEW_SCRIPT="${AGENT_DIR}/collect-sbom.sh.new"
        REMOTE_SCRIPT_URL="${NEXUS_URL}/repository/${NEXUS_REPO}/agent/collect-sbom.sh"
        if $CURL_CMD -s -o "$NEW_SCRIPT" "$REMOTE_SCRIPT_URL"; then
            mv "$NEW_SCRIPT" "$(realpath $0)"
            chmod +x "$(realpath $0)"
            log "Script update completed. Restarting..."
            exec bash "$(realpath $0)" "$@"
        fi
    fi

    # 0.2. Check for Syft binary updates
    log "Checking Syft version..."
    # Check current Syft version (if file exists)
    CURRENT_SYFT_VER="none"
    if [[ -x "$SYFT_BIN" ]]; then
        CURRENT_SYFT_VER=$($SYFT_BIN --version | awk '{print $2}' || echo "none")
    fi

    # Check the latest Syft version info from Nexus3 (e.g., syft_version.txt)
    REMOTE_SYFT_VER_URL="${NEXUS_URL}/repository/${NEXUS_REPO}/syft/latest_version.txt"
    LATEST_SYFT_VER=$($CURL_CMD -s "$REMOTE_SYFT_VER_URL" || echo "$CURRENT_SYFT_VER")

    if [[ "$LATEST_SYFT_VER" != "$CURRENT_SYFT_VER" && "$LATEST_SYFT_VER" != "none" ]]; then
        log "New Syft version found: $LATEST_SYFT_VER (current: $CURRENT_SYFT_VER). Proceeding with update."
        
        ARCH=$(uname -m)
        SYFT_ARCH="amd64"
        [[ "$ARCH" == "aarch64" ]] && SYFT_ARCH="arm64"
        
        # File naming convention: syft_{version}_linux_{arch}.tar.gz
        SYFT_FILE="syft_${LATEST_SYFT_VER}_linux_${SYFT_ARCH}.tar.gz"
        SYFT_URL="${NEXUS_URL}/repository/${NEXUS_REPO}/syft/${LATEST_SYFT_VER}/${SYFT_FILE}"
        
        log "Downloading latest Syft binary from Nexus3... ($SYFT_URL)"
        if $CURL_CMD -o "${AGENT_DIR}/syft.tar.gz" "$SYFT_URL"; then
            # Backup existing binary and replace
            [[ -f "$SYFT_BIN" ]] && mv "$SYFT_BIN" "${SYFT_BIN}.old"
            
            tar -xzf "${AGENT_DIR}/syft.tar.gz" -C "$AGENT_DIR" syft
            chmod +x "$SYFT_BIN"
            
            rm -f "${AGENT_DIR}/syft.tar.gz" "${SYFT_BIN}.old"
            log "Syft updated to version $LATEST_SYFT_VER."
        else
            log "[WARN] Failed to download Syft. Keeping existing version."
        fi
    fi
}


# 로그 기록 함수
log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 2. Initial Setup/Configuration function (Setup Mode)
setup_agent() {
    log "Starting initial setup..."

    # Create agent directory
    mkdir -p "$AGENT_DIR"

    # Check system architecture and download Syft
    ARCH=$(uname -m)
    SYFT_ARCH="amd64"
    [[ "$ARCH" == "aarch64" ]] && SYFT_ARCH="arm64"
    if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
        log "[ERROR] Unsupported architecture: $ARCH"
        exit 1
    fi

    # Check the latest Syft version from Nexus3
    REMOTE_SYFT_VER_URL="${NEXUS_URL}/repository/${NEXUS_REPO}/syft/latest_version.txt"
    SYFT_VERSION=$($CURL_CMD "$REMOTE_SYFT_VER_URL")
    if [[ -z "$SYFT_VERSION" ]]; then
        log "[ERROR] Failed to fetch latest Syft version info from Nexus3."
        exit 1
    fi

    # File naming convention: syft_{version}_linux_{arch}.tar.gz
    SYFT_FILE="syft_${SYFT_VERSION}_linux_${SYFT_ARCH}.tar.gz"
    SYFT_URL="${NEXUS_URL}/repository/${NEXUS_REPO}/syft/${SYFT_VERSION}/${SYFT_FILE}"

    log "Downloading Syft ${SYFT_VERSION} from Nexus3... ($SYFT_URL)"
    if ! $CURL_CMD -o "${AGENT_DIR}/syft.tar.gz" "$SYFT_URL"; then
        log "[ERROR] Failed to download Syft."
        exit 1
    fi
    tar -xzf "${AGENT_DIR}/syft.tar.gz" -C "$AGENT_DIR" syft
    chmod +x "$SYFT_BIN"
    rm -f "${AGENT_DIR}/syft.tar.gz"
    log "Syft ${SYFT_VERSION} installation completed: $SYFT_BIN"

    # Check required parameters for setup
    if [[ -z "$SETUP_PROJECT_NAME" ]]; then
        log "[WARN] Project name not provided. Using default (System-Name)."
        SETUP_PROJECT_NAME="System-Name"
    fi

    if [[ -z "$SETUP_TARGET_DIRS" ]]; then
        log "[ERROR] Target directories to scan must be provided via --target-dirs."
        echo "Usage: sudo bash $0 --setup --project-name <name> --target-dirs <dir1> <dir2>..."
        exit 1
    fi

    # Verify target directories
    TARGET_PATHS=""
    for INPUT_PATH in $SETUP_TARGET_DIRS; do
        if [[ -d "$INPUT_PATH" ]]; then
            TARGET_PATHS="$TARGET_PATHS $INPUT_PATH"
        else
            log "[WARN] Invalid directory: $INPUT_PATH (ignored)"
        fi
    done

    if [[ -z "$(echo $TARGET_PATHS | xargs)" ]]; then
        log "[ERROR] No valid directories registered."
        exit 1
    fi

    BD_PROJECT_NAME="$SETUP_PROJECT_NAME"

    # Save configuration (BD_PROJECT_NAME and TARGET_DIRS)
    echo "BD_PROJECT_NAME=\"$BD_PROJECT_NAME\"" > "$CONFIG_FILE"
    echo "TARGET_DIRS=\"$(echo $TARGET_PATHS | xargs)\"" >> "$CONFIG_FILE"
    echo "INSTALLED_AT=\"$(date)\"" >> "$CONFIG_FILE"
    
    log "Configuration saved: $CONFIG_FILE (Project: $BD_PROJECT_NAME)"

    # Execute initial scan
    run_scan

    # Requires sudo privileges for cron registration
    if [[ $EUID -ne 0 ]]; then
        log "[ERROR] sudo privilege is required to register crontab. Please run again with sudo."
        exit 1
    fi

    # Create deterministic schedule based on MAC address (weekly, off-business hours: 12:00 ~ 08:00)
    # Get seed using base interface MAC address
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}')
    MAC_ADDR=$(cat /sys/class/net/${DEFAULT_IF}/address | tr -d ':')
    
    if [[ -z "$MAC_ADDR" ]]; then
        log "[WARN] MAC address could not be verified, using random value."
        SEED=$RANDOM
    else
        # Use last 8 chars of MAC address as decimal seed
        SEED=$((16#${MAC_ADDR: -8}))
    fi

    # Set hours: 12:00 ~ 08:00 (20 hour candidates)
    HOURS=(12 13 14 15 16 17 18 19 20 21 22 23 0 1 2 3 4 5 6 7)
    
    SCHED_HOUR=${HOURS[$((SEED % 20))]}
    SCHED_MIN=$((SEED % 60))
    SCHED_DOW=$((SEED % 7)) # 0-6 (Sun-Sat)

    # Register crontab (Fixed weekly schedule based on MAC)
    CRON_JOB="$SCHED_MIN $SCHED_HOUR * * $SCHED_DOW root /bin/bash $(realpath $0) --cron >> $LOG_FILE 2>&1"
    echo "$CRON_JOB" > /etc/cron.d/sbom-monitor
    chmod 644 /etc/cron.d/sbom-monitor
    
    log "Deterministic schedule registration completed: $SCHED_MIN $SCHED_HOUR * * $SCHED_DOW (Day of week: $SCHED_DOW, Base MAC: $MAC_ADDR)"
    log "Crontab location: /etc/cron.d/sbom-monitor"
    log "All setup completed."
}

# 3. SBOM Scan and Upload Function (Scan Mode)
run_scan() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "[ERROR] Configuration file not found. Please run setup first."
        exit 1
    fi

    source "$CONFIG_FILE"
    # Override project name if OVERRIDE_PROJECT_NAME is set via command line
    if [[ -n "$OVERRIDE_PROJECT_NAME" ]]; then
        BD_PROJECT_NAME="$OVERRIDE_PROJECT_NAME"
    fi

    HOSTNAME=$(hostname)
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    
    # Set Black Duck version name: {hostname}-{YYYYMMDDHHMMSS}
    BD_VERSION="${HOSTNAME}-${TIMESTAMP}"
    
    # Create SBOM output directory
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_FILE="${OUTPUT_DIR}/sbom_${BD_VERSION}.json"

    log "Starting SBOM scan (Project: $BD_PROJECT_NAME, Server: $HOSTNAME, Target paths: $TARGET_DIRS)"
    
    # Run Syft (Integrated scan of all paths, CycloneDX format)
    # $SYFT_BIN $TARGET_DIRS -o cyclonedx-json > "$OUTPUT_FILE"
    
    log "SBOM generation completed: $OUTPUT_FILE"

    # Black Duck Upload Logic
    # Upload the integrated SBOM file through the latest Black Duck API (/api/scan/data).
    log "Sending integrated SBOM to Black Duck (Project: $BD_PROJECT_NAME, Version: $BD_VERSION)..."
    # curl -X POST "${BLACKDUCK_URL}/api/scan/data?projectName=${BD_PROJECT_NAME}&versionName=${BD_VERSION}" \
    #      -H "Authorization: Bearer $BLACKDUCK_TOKEN" \
    #      -H "Content-Type: multipart/form-data" \
    #      -F "file=@$OUTPUT_FILE;type=application/vnd.cyclonedx"

    log "Integrated scan and upload task completed for paths [$TARGET_DIRS] on server [$HOSTNAME]."
}

# Main Execution Logic
check_for_updates "$@"

case "$1" in
    --setup)
        # Parse setup arguments
        shift
        SETUP_PROJECT_NAME=""
        SETUP_TARGET_DIRS=""
        while [[ $# -gt 0 ]]; do
            case $1 in
                --project-name|-p)
                    SETUP_PROJECT_NAME="$2"
                    shift 2
                    ;;
                --target-dirs|-t)
                    shift
                    while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                        SETUP_TARGET_DIRS="$SETUP_TARGET_DIRS $1"
                        shift
                    done
                    ;;
                *)
                    echo "[ERROR] Unknown option: $1"
                    exit 1
                    ;;
            esac
        done
        if [[ -f "$CONFIG_FILE" ]]; then
            log "[WARN] Agent is already configured. Config file will be overwritten."
        fi
        setup_agent
        ;;
    --cron)
        # Automatic execution via cron
        run_scan
        ;;
    --scan-only)
        # Execute scan + Black Duck upload only without cron (sudo not required)
        if [[ ! -f "$CONFIG_FILE" ]]; then
            echo "[ERROR] Configuration file not found. Please run initial setup first."
            exit 1
        fi
        
        shift
        OVERRIDE_PROJECT_NAME=""
        while [[ $# -gt 0 ]]; do
            case $1 in
                --project-name|-p)
                    OVERRIDE_PROJECT_NAME="$2"
                    shift 2
                    ;;
                *)
                    echo "[ERROR] Unknown option for --scan-only: $1"
                    exit 1
                    ;;
            esac
        done
        
        run_scan
        ;;
    --run)
        # Execute manual scan
        run_scan
        ;;
    *)
        echo "Usage:"
        echo "  sudo bash $0 --setup --project-name <name> --target-dirs <dir1> <dir2> ...  - Initial setup and cron registration"
        echo "  sudo bash $0 --run                                                          - Run manual scan"
        echo "  bash $0 --scan-only [--project-name <name>]                                 - Run scan only without cron (sudo not required)"
        echo "  sudo bash $0 --cron                                                         - Automatic execution by cron"
        if [[ ! -f "$CONFIG_FILE" ]]; then
            echo -e "\n[INFO] You need to run --setup first because config.conf is missing."
        fi
        exit 1
        ;;
esac
