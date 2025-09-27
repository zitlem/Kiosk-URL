#!/bin/bash
#   Initial setup:    sudo $0 setup
#   Management:       ./kiosk-setup.sh <command>  
#   Help:            ./kiosk-setup.sh help

set -e

KIOSK_USER="kiosk"
INSTALL_DIR="/opt/kiosk"
CONFIG_FILE="$INSTALL_DIR/kiosk.json"
SERVICE_FILE="/etc/systemd/system/kiosk.service"
API_SERVICE_FILE="/etc/systemd/system/kiosk-api.service"
SETUP_MARKER="$INSTALL_DIR/.setup_complete"
DEBUG_PORT=9222
CHROMIUM_PATH=""


ARCH=$(uname -m)
IS_ARM=false
IS_RPI=false

case "$ARCH" in
    armv6l|armv7l|aarch64|arm64)
        IS_ARM=true
        if [[ -f /proc/device-tree/model ]] && grep -qi "raspberry pi" /proc/device-tree/model; then
            IS_RPI=true
        fi
        ;;
esac

# ==========================================
# PACKAGE DEFINITIONS
# ==========================================

# Package lists - architecture-specific
SYSTEM_PACKAGES=(
    # Essential X11 and display components
    "xserver-xorg"
    "x11-xserver-utils"
    "xinit"
    "openbox"
    "unclutter"

    # Essential system fonts and desktop base
    "xfonts-base"
    "desktop-file-utils"
    "dbus-x11"

    # Core system tools
    "python3"
    "python3-pip"
    "python3-xdg"
    "curl"
    "jq"
    "gnupg"
    "ca-certificates"
    "coreutils"
    "openssl"
    "nano"
    "htop"
)

ARM_PACKAGES=(
    "chromium-browser"

    # ARM-specific display drivers
    "xserver-xorg-video-fbdev"
    "xserver-xorg-input-evdev"
)

# Raspberry Pi specific packages (only for actual Raspberry Pi hardware)
RPI_PACKAGES=(
    # Raspberry Pi core libraries and optimizations
    "rpi-chromium-mods"
    "libraspberrypi-bin"
    "libraspberrypi0"

    # Hardware support and firmware
    "raspberrypi-kernel-headers"
    "firmware-brcm80211"
    "rpi-eeprom"
    "raspi-config"

    # Desktop environment for Lite -> Desktop transformation
    "lxde-core"
    "lightdm"
    "pcmanfm"
    "lxterminal"

    # Network and connectivity
    "network-manager"
    "wireless-tools"
    "wpasupplicant"

    # Bluetooth support
    "pi-bluetooth"
    "bluez"
    "bluez-tools"

    # Audio and media
    "alsa-utils"
    "pulseaudio"
    "feh"

    # Additional fonts and accessibility
    "xfonts-100dpi"
    "xfonts-75dpi"
    "at-spi2-core"

    # File management
    "file-roller"
    "gvfs"
    "gvfs-backends"

    # System utilities
    "lsof"
    "rsync"
)

X86_PACKAGES=(
    "chromium-browser"

    # x86-specific display drivers
    "xserver-xorg-video-intel"
    "xserver-xorg-video-nouveau"
    "xserver-xorg-video-radeon"
    "xserver-xorg-input-libinput"

    # GPU acceleration for x86
    "mesa-utils"
    "libgl1-mesa-dri"
    "vainfo"

    # Desktop environment for x86 Lite -> Desktop transformation
    "lxde-core"
    "lightdm"
    "pcmanfm"
    "lxterminal"

    # Network and connectivity
    "network-manager"
    "wireless-tools"
    "wpasupplicant"

    # Audio and media
    "alsa-utils"
    "pulseaudio"
    "feh"

    # Additional fonts and accessibility
    "xfonts-100dpi"
    "xfonts-75dpi"
    "at-spi2-core"

    # File management
    "file-roller"
    "gvfs"
    "gvfs-backends"

    # System utilities
    "lsof"
    "rsync"
)

PYTHON_PACKAGES=(
    "flask"
    "requests"
    "websocket-client"
)

# ==========================================
# COLORS AND CONFIGURATION
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Error handling configuration
ERROR_LOG="/var/log/kiosk-errors.log"
RETRY_COUNT=3
RETRY_DELAY=5
HEALTH_CHECK_INTERVAL=30
# PAGE_REFRESH_INTERVAL removed - auto-refresh handles page refreshing when enabled
# IFRAME_CHECK_INTERVAL removed - auto-refresh handles page health
BROWSER_RESTART_THRESHOLD=5
# Dynamic browser memory limit based on system RAM (more generous allocation)
SYSTEM_MEMORY_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [[ $SYSTEM_MEMORY_KB -gt 8388608 ]]; then
    # >8GB RAM: Allow browser to use 6GB (75%)
    BROWSER_MEMORY_LIMIT=6291456
elif [[ $SYSTEM_MEMORY_KB -gt 4194304 ]]; then
    # 4-8GB RAM: Allow browser to use 4GB (67%)
    BROWSER_MEMORY_LIMIT=4194304
elif [[ $SYSTEM_MEMORY_KB -gt 2097152 ]]; then
    # 2-4GB RAM: Allow browser to use 2.5GB (70%)
    BROWSER_MEMORY_LIMIT=2621440
elif [[ $SYSTEM_MEMORY_KB -gt 1048576 ]]; then
    # 1-2GB RAM: Allow browser to use 1.2GB (65%)
    BROWSER_MEMORY_LIMIT=1228800
else
    # <1GB RAM: Allow browser to use 700MB (70%)
    BROWSER_MEMORY_LIMIT=716800
fi
# Memory leak detection removed - fast browser restart is more effective

# URL playlist configuration
DEFAULT_DISPLAY_TIME=30       # Default seconds per URL
PLAYLIST_MODE=false          # Single URL mode by default
CURRENT_URL_INDEX=0         # Current position in playlist

# ==========================================
# UTILITY FUNCTIONS
# ==========================================

sanitize_input() {
    local input="$1"
    # Remove dangerous shell metacharacters
    echo "$input" | sed 's/[;&|`$(){}[\]\\]//g'
}

sanitize_path() {
    local path="$1"
    # Allow only safe path characters
    echo "$path" | sed 's/[^a-zA-Z0-9./_ -]//g'
}

validate_command() {
    local cmd="$1"

    if [[ "$cmd" =~ ^[a-zA-Z0-9_./\ -]+$ ]]; then
        return 0
    else
        log_error "Invalid command format: $cmd"
        return 1
    fi
}

log_info() {
    local msg="$1"
    echo -e "${GREEN}[INFO]${NC} $msg" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $msg" >> "$ERROR_LOG" 2>/dev/null || true
}

log_warn() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} $msg" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $msg" >> "$ERROR_LOG" 2>/dev/null || true
}

log_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $msg" >> "$ERROR_LOG" 2>/dev/null || true
}

log_debug() {
    local msg="$1"
    echo -e "${BLUE}[DEBUG]${NC} $msg" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $msg" >> "$ERROR_LOG" 2>/dev/null || true
}

log_title() {
    local title="$1"
    echo -e "${CYAN}=== $title ===${NC}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [TITLE] === $title ===" >> "$ERROR_LOG" 2>/dev/null || true
}

log_critical() {
    local msg="$1"
    echo -e "${MAGENTA}[CRITICAL]${NC} $msg" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRITICAL] $msg" >> "$ERROR_LOG" 2>/dev/null || true
}


handle_error() {
    local exit_code=$1
    local line_number=$2
    local command="$3"
    
    log_critical "Command failed with exit code $exit_code on line $line_number: $command"
    

    save_debug_state
    

    attempt_recovery "$exit_code" "$command"
}

save_debug_state() {
    local debug_dir="/tmp/kiosk-debug-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$debug_dir" 2>/dev/null || return 1
    
    {
        echo "=== SYSTEM INFO ==="
        uname -a
        echo
        echo "=== PROCESSES ==="
        ps aux | grep -E "(chromium|Xorg|openbox|kiosk)" || true
        echo
        echo "=== MEMORY ==="
        free -h
        echo
        echo "=== DISK SPACE ==="
        df -h / 2>/dev/null || echo "Disk info unavailable"
        echo
        echo "=== SERVICES ==="
        systemctl status kiosk.service kiosk-api.service 2>/dev/null || true
        echo
        echo "=== DISPLAY ==="
        DISPLAY=:0 xrandr --query 2>/dev/null || echo "No display available"
        echo
        echo "=== NETWORK ==="
        ip addr show || ifconfig || true
        echo
        echo "=== LOGS ==="
        tail -20 /var/log/syslog 2>/dev/null || true
    } > "$debug_dir/system-state.txt" 2>/dev/null
    
    log_info "Debug state saved to: $debug_dir"
}

attempt_recovery() {
    local exit_code=$1
    local command="$2"
    
    case "$command" in
        *chromium*|*browser*)
            log_warn "Browser command failed, attempting recovery..."
            recover_browser
            ;;
        *systemctl*)
            log_warn "Service command failed, checking service status..."
            recover_services
            ;;
        *xrandr*)
            log_warn "Display command failed, resetting display..."
            recover_display
            ;;
        *apt-get*|*pip*)
            log_warn "Package installation failed, updating repositories..."
            recover_packages
            ;;
        *)
            log_warn "Generic recovery for failed command: $command"
            ;;
    esac
}

recover_browser() {
    log_info "Fast browser restart (no service restart)..."

    # Signal the startup script to restart the browser
    local service_pid
    service_pid=$(cat /tmp/kiosk-service.pid 2>/dev/null || echo "")

    if [[ -n "$service_pid" ]] && kill -0 "$service_pid" 2>/dev/null; then
        log_debug "Signaling service PID $service_pid to restart browser"
        kill -USR1 "$service_pid" 2>/dev/null

        # Wait for browser restart to complete
        local wait_count=0
        local max_wait=10
        local browser_restarted=false

        while [[ $wait_count -lt $max_wait ]]; do
            sleep 1
            ((wait_count++))

            # Check if new browser process is running
            if pgrep -f "chromium.*user-data-dir=/tmp/chromium-kiosk" >/dev/null; then
                browser_restarted=true
                break
            fi
        done

        if [[ "$browser_restarted" == true ]]; then
            log_info "Browser restarted successfully via signal (took ${wait_count}s)"
        else
            log_warn "Signal restart failed after ${max_wait}s, falling back to service restart..."
            systemctl restart kiosk.service || log_error "Failed to restart kiosk service"
        fi
    else
        log_warn "Cannot find service PID, falling back to service restart..."
        systemctl restart kiosk.service || log_error "Failed to restart kiosk service"
    fi
}

recover_services() {
    log_info "Attempting service recovery..."
    
    systemctl daemon-reload
    
    for service in kiosk.service kiosk-api.service; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            log_info "Restarting $service..."
            systemctl restart "$service" || log_error "Failed to restart $service"
        fi
    done
}

recover_display() {
    log_info "Attempting display recovery..."
    

    pkill -f "X :0" 2>/dev/null || true
    sleep 2
    

    if [[ "${0##*/}" == "start_kiosk.sh" ]] || systemctl is-active kiosk.service >/dev/null; then
        log_info "Restarting X server..."
        X :0 -nolisten tcp -noreset +extension GLX vt1 &
        sleep 3
    fi
}

recover_packages() {
    log_info "Attempting package recovery..."
    

    apt-get install -f -y 2>/dev/null || true
    

    apt-get update 2>/dev/null || log_warn "Failed to update package lists"
}


retry_command() {
    local max_attempts="${1:-$RETRY_COUNT}"
    local delay="${2:-$RETRY_DELAY}"
    shift 2
    local command=("$@")

    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        log_debug "Attempt $attempt/$max_attempts: ${command[*]}"

        if "${command[@]}"; then
            log_debug "Command succeeded on attempt $attempt"
            return 0
        fi
        
        local exit_code=$?
        log_warn "Command failed on attempt $attempt with exit code $exit_code"
        
        if [[ $attempt -lt $max_attempts ]]; then
            log_info "Waiting ${delay}s before retry..."
            sleep "$delay"
        fi
        
        ((attempt++))
    done
    
    log_error "Command failed after $max_attempts attempts: $command"
    return 1
}


validate_url() {
    local url="$1"
    
    if [[ -z "$url" ]]; then
        log_error "URL cannot be empty"
        return 1
    fi
    

    if [[ ! "$url" =~ ^https?://[[:alnum:].-]+(:[0-9]+)?(/.*)?$ ]]; then
        log_error "Invalid URL format: $url"
        return 1
    fi
    

    if [[ "$url" =~ (javascript:|data:|file:|ftp:) ]]; then
        log_error "Potentially unsafe URL scheme: $url"
        return 1
    fi
    

    if [[ ${#url} -gt 2048 ]]; then
        log_error "URL too long (max 2048 characters): ${#url}"
        return 1
    fi
    
    log_debug "URL validation passed: $url"
    return 0
}

validate_rotation() {
    local rotation="$1"
    local valid_rotations=("normal" "left" "right" "inverted")
    
    if [[ -z "$rotation" ]]; then
        log_error "Rotation cannot be empty"
        return 1
    fi
    

    rotation=$(echo "$rotation" | tr '[:upper:]' '[:lower:]')
    
    for valid in "${valid_rotations[@]}"; do
        if [[ "$rotation" == "$valid" ]]; then
            log_debug "Rotation validation passed: $rotation"
            return 0
        fi
    done
    
    log_error "Invalid rotation: $rotation (valid: ${valid_rotations[*]})"
    return 1
}

validate_api_key() {
    local key="$1"
    
    if [[ -z "$key" ]]; then
        log_error "API key cannot be empty"
        return 1
    fi
    

    if [[ ${#key} -lt 16 ]]; then
        log_error "API key too short (minimum 16 characters)"
        return 1
    fi
    
    if [[ ${#key} -gt 128 ]]; then
        log_error "API key too long (maximum 128 characters)"
        return 1
    fi
    

    if [[ ! "$key" =~ ^[A-Za-z0-9_-]+$ ]]; then
        log_error "API key contains invalid characters (only alphanumeric, underscore, hyphen allowed)"
        return 1
    fi
    
    log_debug "API key validation passed"
    return 0
}

validate_display_time() {
    local time="$1"
    
    if [[ -z "$time" ]]; then
        log_error "Display time cannot be empty"
        return 1
    fi
    

    if [[ ! "$time" =~ ^[0-9]+$ ]]; then
        log_error "Display time must be a positive integer (seconds)"
        return 1
    fi
    

    if [[ $time -lt 5 ]]; then
        log_error "Display time too short (minimum 5 seconds)"
        return 1
    fi
    
    if [[ $time -gt 86400 ]]; then
        log_error "Display time too long (maximum 24 hours)"
        return 1
    fi
    
    log_debug "Display time validation passed: ${time}s"
    return 0
}

validate_playlist_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Playlist config file not found: $config_file"
        return 1
    fi
    

    if ! python3 -m json.tool "$config_file" >/dev/null 2>&1; then
        log_error "Invalid JSON in playlist config: $config_file"
        return 1
    fi
    

    local required_fields=("enabled" "urls")
    for field in "${required_fields[@]}"; do
        if ! grep -q "\"$field\"" "$config_file"; then
            log_error "Missing required field in playlist config: $field"
            return 1
        fi
    done
    

    local urls
    urls=$(python3 -c "
import json
with open('$config_file', 'r') as f:
    data = json.load(f)
    for item in data.get('playlist', {}).get('urls', []):
        print(item.get('url', ''))
" 2>/dev/null)
    
    if [[ -z "$urls" ]]; then
        log_error "No URLs found in playlist"
        return 1
    fi
    
    while IFS= read -r url; do
        if [[ -n "$url" ]] && ! validate_url "$url"; then
            log_error "Invalid URL in playlist: $url"
            return 1
        fi
    done <<< "$urls"
    
    log_debug "Playlist config validation passed"
    return 0
}


validate_config_file() {
    local config_file="$1"
    local config_type="$2"
    
    if [[ ! -f "$config_file" ]]; then
        log_warn "Config file missing: $config_file"
        return 1
    fi
    
    case "$config_type" in
        "url")
            local url
            url=$(cat "$config_file" 2>/dev/null)
            validate_url "$url"
            ;;
        "rotation")
            local rotation
            rotation=$(cat "$config_file" 2>/dev/null)
            validate_rotation "$rotation"
            ;;
        "api")
            if ! python3 -m json.tool "$config_file" >/dev/null 2>&1; then
                log_error "Invalid JSON in API config: $config_file"
                return 1
            fi
            log_debug "API config JSON validation passed"
            ;;
        "playlist")
            validate_playlist_config "$config_file"
            ;;
        *)
            log_warn "Unknown config type: $config_type"
            return 1
            ;;
    esac
}



create_default_config() {
    log_info "Creating default unified configuration..."

    mkdir -p "$(dirname "$CONFIG_FILE")"


    local existing_api_key=""
    if [[ -f "$CONFIG_FILE" ]]; then
        existing_api_key=$(get_config_value "api.api_key" 2>/dev/null || echo "")
    fi


    local api_key="$existing_api_key"
    if [[ -z "$api_key" ]]; then
        api_key=$(generate_api_key)
    fi

    local default_config='{
  "kiosk": {
    "url": "http://example.com",
    "rotation": "normal"
  },
  "api": {
    "api_key": "'"$api_key"'",
    "port": 80
  },
  "playlist": {
    "enabled": false,
    "default_display_time": 30,
    "urls": [
      {
        "url": "http://example.com",
        "display_time": 30,
        "title": "Example Site"
      }
    ]
  }
}'
    
    echo "$default_config" > "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    
    log_debug "Default unified configuration created"
}

get_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        create_default_config
    fi
    

    if [[ ! -s "$CONFIG_FILE" ]]; then
        create_default_config
    fi
    

    if cat "$CONFIG_FILE" 2>/dev/null | python3 -c "import json, sys; json.load(sys.stdin)" >/dev/null 2>&1; then
        cat "$CONFIG_FILE"
    else
        log_warn "Invalid config detected, attempting to repair"
        

        local backup_content=""
        if [[ -f "$CONFIG_FILE" ]] && [[ -s "$CONFIG_FILE" ]]; then
            backup_content=$(cat "$CONFIG_FILE" 2>/dev/null || echo "")
        fi
        

        create_default_config
        

        if [[ -n "$backup_content" ]]; then
            log_debug "Attempting to merge existing settings"
            

            export KIOSK_CONFIG_FILE="${CONFIG_FILE:-/opt/kiosk/kiosk.json}"
            export KIOSK_BACKUP_CONTENT="$backup_content"
            python3 -c "
import json
import sys
import os

try:
    config_file = os.environ['KIOSK_CONFIG_FILE']
    backup_content = os.environ['KIOSK_BACKUP_CONTENT']
    

    with open(config_file, 'r') as f:
        default_config = json.load(f)
    

    
    try:
        backup_config = json.loads(backup_content)
        

        for key, value in backup_config.items():
            if key not in ['kiosk', 'playlist']:
                default_config[key] = value
            elif isinstance(value, dict) and key in default_config:

                for subkey, subvalue in value.items():
                    if subkey not in default_config[key]:
                        default_config[key][subkey] = subvalue
        

        with open(config_file, 'w') as f:
            json.dump(default_config, f, indent=2)
            
        print('Merged settings from backup', file=sys.stderr)
        
    except json.JSONDecodeError:
        print('Backup config invalid, using defaults', file=sys.stderr)
        
except Exception as e:
    print(f'Merge failed: {e}', file=sys.stderr)
" 2>/dev/null
        fi
        
        cat "$CONFIG_FILE"
    fi
}

get_config_value() {
    local key_path="$1"
    local default_value="${2:-}"
    

    export KIOSK_KEY_PATH="$key_path"
    export KIOSK_DEFAULT_VALUE="$default_value"
    
    get_config | python3 -c "
import json, sys, os
try:
    key_path = os.environ['KIOSK_KEY_PATH']
    default_value = os.environ['KIOSK_DEFAULT_VALUE']
    
    data = json.load(sys.stdin)
    
    keys = key_path.split('.')
    value = data
    for key in keys:
        value = value[key]
    print(value)
except Exception as e:
    print(default_value)
"
    

    unset KIOSK_KEY_PATH KIOSK_DEFAULT_VALUE
}

set_config_value() {
    local key_path="$1"
    local new_value="$2"
    

    export KIOSK_CONFIG_FILE="${CONFIG_FILE:-/opt/kiosk/kiosk.json}"
    export KIOSK_KEY_PATH="$key_path"
    export KIOSK_NEW_VALUE="$new_value"
    
    python3 -c "
import json
import os
import sys

try:
    config_file = os.environ['KIOSK_CONFIG_FILE']
    key_path = os.environ['KIOSK_KEY_PATH']
    new_value = os.environ['KIOSK_NEW_VALUE']
    
    try:
        with open(config_file, 'r') as f:
            data = json.load(f)
    except Exception as e:
        data = {}

    keys = key_path.split('.')
    current = data
    for key in keys[:-1]:
        if key not in current:
            current[key] = {}
        current = current[key]


    if new_value.lower() == 'true':
        current[keys[-1]] = True
    elif new_value.lower() == 'false': 
        current[keys[-1]] = False
    elif new_value.isdigit():
        current[keys[-1]] = int(new_value)
    else:
        current[keys[-1]] = new_value


    import tempfile
    import os
    
    temp_file = config_file + '.tmp'
    with open(temp_file, 'w') as f:
        json.dump(data, f, indent=2)
    

    with open(temp_file, 'r') as f:
        json.load(f)
    

    os.replace(temp_file, config_file)
    
    print('SUCCESS')
    
except Exception as e:
    print(f'ERROR: Failed to update config: {e}', file=sys.stderr)
    print(f'DEBUG: Config file path was: {config_file}', file=sys.stderr)

    print('FAILED')
" || {
        log_error "Failed to update configuration file"
        return 1
    }
    

    unset KIOSK_CONFIG_FILE KIOSK_KEY_PATH KIOSK_NEW_VALUE
    
    log_debug "Configuration updated successfully"
}

# check_iframe_health() removed - auto-refresh handles page health

check_browser_responsive() {
    local debug_port=$DEBUG_PORT

    # Check if DevTools API is responsive
    if ! timeout 5 curl -s "http://localhost:$debug_port/json" >/dev/null 2>&1; then
        log_warn "Browser DevTools not responsive"
        return 1
    fi

    # Check if processes are in zombie/uninterruptible state
    local zombie_count=0
    if pgrep -f chromium >/dev/null 2>&1; then
        local temp_count
        temp_count=$(pgrep -f chromium | xargs -r ps -o stat= -p 2>/dev/null | grep -c '[ZD]' 2>/dev/null || echo "0")
        # Clean and validate the count
        temp_count=$(echo "$temp_count" | tr -cd '0-9' | head -c 10)
        zombie_count=${temp_count:-0}
    fi
    if [[ $zombie_count -gt 0 ]]; then
        log_warn "Browser has $zombie_count zombie/hung processes"
        return 1
    fi

    # Iframe health checking removed - auto-refresh handles page health

    return 0
}

check_browser_crash() {
    # Check for crash reports
    if [[ -d /tmp/chromium-kiosk/Crash\ Reports/pending ]] && [[ -n "$(ls -A /tmp/chromium-kiosk/Crash\ Reports/pending/ 2>/dev/null)" ]]; then
        log_warn "Browser crash detected, clearing crash reports and restarting"
        rm -rf /tmp/chromium-kiosk/Crash\ Reports/* 2>/dev/null || true
        return 0  # Crash detected
    fi

    # Check if browser is responsive
    if ! check_browser_responsive; then
        log_warn "Browser unresponsive, treating as crash"
        return 0  # Unresponsive = crash
    fi

    return 1  # No crash
}

# refresh_iframes() removed - auto-refresh handles page health

# refresh_browser_page() removed - fast browser restart is more effective

# cleanup_browser_memory() removed - fast browser restart is more effective than cleanup

get_browser_memory_kb() {
    local chromium_pids
    chromium_pids=$(pgrep -f chromium 2>/dev/null)

    if [[ -z "$chromium_pids" ]]; then
        echo "0"
        return
    fi



    local memory_kb
    memory_kb=$(echo "$chromium_pids" | xargs -r ps -o rss= -p 2>/dev/null | awk '{sum+=$1} END {printf "%.0f", sum+0}')


    local max_reasonable_kb=$((10 * 1024 * 1024))  # 10GB in KB

    if [[ -z "$memory_kb" || "$memory_kb" == "0" ]]; then
        echo "0"
    elif [[ "$memory_kb" -gt "$max_reasonable_kb" ]]; then
        log_warn "Browser memory calculation error detected: ${memory_kb}KB seems unrealistic"
        echo "0"
    else
        echo "$memory_kb"
    fi
}

validate_config() {
    local config_file="${CONFIG_FILE:-/opt/kiosk/kiosk.json}"
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    export KIOSK_CONFIG_FILE="$config_file"
    python3 -c "
import json
import os
try:
    config_file = os.environ['KIOSK_CONFIG_FILE']
    with open(config_file, 'r') as f:
        data = json.load(f)
    

    if 'kiosk' not in data:
        exit(1)
    

    if 'url' not in data['kiosk']:
        exit(1)
        
    exit(0)
except:
    exit(1)
"
}




create_default_playlist() {
    create_default_config
}

get_playlist_config() {
    get_config | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    playlist = data.get('playlist', {})
    print(json.dumps(playlist))
except:
    print('{}')
"
}

is_playlist_enabled() {
    get_config_value "playlist.enabled" "false"
}

get_playlist_urls() {
    local config
    config=$(get_playlist_config)


    KIOSK_CONFIG="$config" python3 -c "
import json, os
try:
    config_data = os.environ.get('KIOSK_CONFIG', '{}')
    data = json.loads(config_data)
    for i, item in enumerate(data.get('urls', [])):
        url = item.get('url', '')
        time = item.get('display_time', data.get('default_display_time', $DEFAULT_DISPLAY_TIME))
        title = item.get('title', f'URL {i+1}')
        print(f'{i}|{url}|{time}|{title}')
except Exception as e:
    pass
" 2>/dev/null
}

get_current_playlist_url() {
    local urls_info
    urls_info=$(get_playlist_urls)
    
    if [[ -z "$urls_info" ]]; then
        get_url
        return
    fi
    
    local total_urls
    total_urls=$(echo "$urls_info" | wc -l)
    

    local current_index=0
    if [[ -f "/tmp/kiosk-playlist-index" ]]; then
        current_index=$(cat "/tmp/kiosk-playlist-index" 2>/dev/null || echo "0")
    fi
    

    if [[ $current_index -ge $total_urls ]]; then
        current_index=0
    fi
    

    local url_info
    url_info=$(echo "$urls_info" | sed -n "$((current_index + 1))p")
    
    if [[ -n "$url_info" ]]; then
        echo "$url_info" | cut -d'|' -f2
    else
        get_url
    fi
}

get_current_playlist_display_time() {
    local urls_info
    urls_info=$(get_playlist_urls)
    
    if [[ -z "$urls_info" ]]; then
        echo "$DEFAULT_DISPLAY_TIME"
        return
    fi
    
    local current_index=0
    if [[ -f "/tmp/kiosk-playlist-index" ]]; then
        current_index=$(cat "/tmp/kiosk-playlist-index" 2>/dev/null || echo "0")
    fi
    
    local total_urls
    total_urls=$(echo "$urls_info" | wc -l)
    
    if [[ $current_index -ge $total_urls ]]; then
        current_index=0
    fi
    
    local url_info
    url_info=$(echo "$urls_info" | sed -n "$((current_index + 1))p")
    
    if [[ -n "$url_info" ]]; then
        echo "$url_info" | cut -d'|' -f3
    else
        echo "$DEFAULT_DISPLAY_TIME"
    fi
}

advance_playlist() {
    local urls_info
    urls_info=$(get_playlist_urls)
    
    if [[ -z "$urls_info" ]]; then
        return 1
    fi
    
    local current_index=0
    if [[ -f "/tmp/kiosk-playlist-index" ]]; then
        current_index=$(cat "/tmp/kiosk-playlist-index" 2>/dev/null || echo "0")
    fi
    
    local total_urls
    total_urls=$(echo "$urls_info" | wc -l)
    

    current_index=$((current_index + 1))
    

    if [[ $current_index -ge $total_urls ]]; then
        current_index=0
    fi
    

    echo "$current_index" > "/tmp/kiosk-playlist-index"
    
    log_debug "Advanced playlist to index: $current_index"
}

start_playlist_cycling() {
    log_info "Starting playlist cycling..."
    
    while true; do
        local current_url
        current_url=$(get_current_playlist_url)
        
        local display_time
        display_time=$(get_current_playlist_display_time)
        
        log_info "Displaying URL: $current_url for ${display_time}s"
        

        navigate_browser_to_url "$current_url"
        

        sleep "$display_time"
        

        advance_playlist
        

        if [[ "$(is_playlist_enabled)" != "true" ]]; then
            log_info "Playlist disabled, stopping rotation"
            break
        fi
    done
}

start_playlist_cycling_service() {
    log_info "Starting playlist cycling service in background..."


    if [[ -f "/tmp/kiosk-playlist-cycling.pid" ]]; then
        local old_pid
        old_pid=$(cat "/tmp/kiosk-playlist-cycling.pid" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            log_debug "Stopping existing playlist cycling service (PID: $old_pid)"
            kill "$old_pid" 2>/dev/null
            sleep 1
        fi
        rm -f "/tmp/kiosk-playlist-cycling.pid"
    fi


    cat > "$INSTALL_DIR/kiosk-cycling-worker.sh" << EOF
#!/bin/bash
CONFIG_FILE="$CONFIG_FILE"
DEFAULT_DISPLAY_TIME="$DEFAULT_DISPLAY_TIME"
DEBUG_PORT="$DEBUG_PORT"

echo "Playlist cycling service starting..." >> /tmp/kiosk-cycling.log
echo "Using config file: \$CONFIG_FILE" >> /tmp/kiosk-cycling.log
sleep 8


echo "Config file contents:" >> /tmp/kiosk-cycling.log
cat "\$CONFIG_FILE" >> /tmp/kiosk-cycling.log 2>/dev/null || echo "Config file not found" >> /tmp/kiosk-cycling.log


echo "Testing DevTools connectivity on port \$DEBUG_PORT..." >> /tmp/kiosk-cycling.log
python3 -c "
import urllib.request
try:
    req = urllib.request.Request('http://localhost:\$DEBUG_PORT/json')
    with urllib.request.urlopen(req, timeout=3) as response:
        print('DevTools accessible - browser is running')
except Exception as e:
    print(f'DevTools NOT accessible: {e}')
" >> /tmp/kiosk-cycling.log 2>&1


INITIAL_CHECK=\$(python3 -c "
import json
try:
    with open('\$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    enabled = data.get('playlist', {}).get('enabled', False)
    url_count = len(data.get('playlist', {}).get('urls', []))
    print(f'{\\"true\\" if enabled else \\"false\\"}|{url_count}')
except:
    print('false|0')
" 2>/dev/null)

INITIAL_ENABLED=\$(echo "\$INITIAL_CHECK" | cut -d'|' -f1)
INITIAL_URL_COUNT=\$(echo "\$INITIAL_CHECK" | cut -d'|' -f2)

echo "Initial check: enabled=\$INITIAL_ENABLED, urls=\$INITIAL_URL_COUNT" >> /tmp/kiosk-cycling.log

if [[ "\$INITIAL_ENABLED" != "true" ]] || [[ "\$INITIAL_URL_COUNT" -le 1 ]]; then
    echo "ERROR: Playlist not properly configured for cycling. Exiting." >> /tmp/kiosk-cycling.log
    exit 1
fi

while true; do
    echo "[$(date)] Checking playlist cycling..." >> /tmp/kiosk-cycling.log
    echo "[$(date)] Reading config from: \$CONFIG_FILE" >> /tmp/kiosk-cycling.log

    DISPLAY_TIME=\$(python3 -c "
import json
try:
    with open('\$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    urls = data.get('playlist', {}).get('urls', [])


    current_index = 0
    try:
        with open('/tmp/kiosk-playlist-index', 'r') as idx_file:
            current_index = int(idx_file.read().strip())
    except:
        pass

    if current_index < len(urls):
        display_time = urls[current_index].get('display_time', data.get('playlist', {}).get('default_display_time', \$DEFAULT_DISPLAY_TIME))
        print(display_time)
    else:
        print(\$DEFAULT_DISPLAY_TIME)
except:
    print(\$DEFAULT_DISPLAY_TIME)
" 2>/dev/null)

    echo "[$(date)] Waiting \${DISPLAY_TIME}s for current URL..." >> /tmp/kiosk-cycling.log
    sleep "\$DISPLAY_TIME"


    PLAYLIST_INFO=\$(python3 -c "
import json
import sys
try:
    config_path = '\$CONFIG_FILE'
    print(f'DEBUG: Reading from {config_path}', file=sys.stderr)
    with open(config_path, 'r') as f:
        data = json.load(f)

    playlist_data = data.get('playlist', {})
    enabled = playlist_data.get('enabled', False)
    urls = playlist_data.get('urls', [])
    url_count = len(urls)

    print(f'DEBUG: playlist section = {playlist_data}', file=sys.stderr)
    print(f'{\\"true\\" if enabled else \\"false\\"}|{url_count}')
except Exception as e:
    print(f'DEBUG: Exception reading config: {e}', file=sys.stderr)
    print('false|0')
" 2>>/tmp/kiosk-cycling.log)

    STILL_ENABLED=\$(echo "\$PLAYLIST_INFO" | cut -d'|' -f1)
    URL_COUNT=\$(echo "\$PLAYLIST_INFO" | cut -d'|' -f2)

    echo "[$(date)] Playlist status: enabled=\$STILL_ENABLED, urls=\$URL_COUNT" >> /tmp/kiosk-cycling.log

    if [[ "\$STILL_ENABLED" != "true" ]] || [[ "\$URL_COUNT" -le 1 ]]; then
        echo "[$(date)] Playlist disabled or single URL mode, stopping cycling" >> /tmp/kiosk-cycling.log
        break
    fi


    python3 -c "
import json


current_index = 0
try:
    with open('/tmp/kiosk-playlist-index', 'r') as f:
        current_index = int(f.read().strip())
except:
    pass

try:
    with open('\$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    total_urls = len(data.get('playlist', {}).get('urls', []))

    if total_urls > 1:

        current_index = (current_index + 1) % total_urls

        with open('/tmp/kiosk-playlist-index', 'w') as f:
            f.write(str(current_index))


        next_url = data['playlist']['urls'][current_index]['url']
        print(f'[{current_index}] Navigating to: {next_url}')


        import subprocess

        try:

            nav_script = f'''
source /opt/kiosk/kiosk-setup.sh
navigate_browser_to_url "{next_url}"
'''
            nav_result = subprocess.run(
                ['bash', '-c', nav_script],
                capture_output=True,
                text=True,
                timeout=15,
                cwd='/opt/kiosk'
            )

            if nav_result.returncode == 0:
                print(f'Successfully navigated to: {next_url}')
            else:
                print(f'Navigation failed: {nav_result.stderr.strip()}')

        except Exception as nav_error:
            print(f'Navigation error: {nav_error}')
except Exception as e:
    print(f'Error in playlist cycling: {e}')
" >> /tmp/kiosk-cycling.log 2>&1
done


rm -f "/tmp/kiosk-playlist-cycling.pid"
EOF

    chmod +x "$INSTALL_DIR/kiosk-cycling-worker.sh"


    nohup "$INSTALL_DIR/kiosk-cycling-worker.sh" >/dev/null 2>&1 &

    local cycling_pid=$!
    echo "$cycling_pid" > "/tmp/kiosk-playlist-cycling.pid"
    log_info "Playlist cycling service started (PID: $cycling_pid)"
}

navigate_browser_to_url() {
    local url="$1"
    
    if [[ -z "$url" ]]; then
        log_error "No URL provided for navigation"
        return 1
    fi
    
    validate_url "$url" || {
        log_error "Invalid URL for navigation: $url"
        return 1
    }
    

    if command -v curl >/dev/null; then
        log_debug "Attempting DevTools navigation to: $url"
        

        local devtools_test
        devtools_test=$(curl -s --connect-timeout 2 "http://localhost:$DEBUG_PORT/json" 2>/dev/null)
        
        if [[ -z "$devtools_test" ]]; then
            log_warn "DevTools not accessible on port $DEBUG_PORT"
        else
            log_debug "DevTools accessible, getting tab info"
            
            local tab_info
            tab_info=$(echo "$devtools_test" | python3 -c "
import json, sys
try:
    tabs = json.load(sys.stdin)
    if tabs:
        print(tabs[0]['id'])
except Exception as e:
    print('ERROR: ' + str(e), file=sys.stderr)
" 2>/dev/null)
            
            if [[ -n "$tab_info" ]]; then
                log_debug "Found tab ID: $tab_info, sending navigation command"
                

                log_debug "Trying Runtime.evaluate navigation [NEW VERSION 2.0]"
                

                export NAVIGATE_URL="$url"
                local nav_result
                nav_result=$(python3 -c "
import json
import urllib.request
import urllib.parse
import os
import sys

url_to_navigate = os.environ['NAVIGATE_URL']
tab_id = '$tab_info'
debug_port = '$DEBUG_PORT'

print(f'DEBUG: Navigating to {url_to_navigate} on tab {tab_id} port {debug_port}', file=sys.stderr)


try:

    encoded_url = urllib.parse.quote(url_to_navigate, safe='')
    new_tab_url = f'http://localhost:{debug_port}/json/new?{encoded_url}'
    print(f'DEBUG: Trying GET new tab: {new_tab_url}', file=sys.stderr)
    
    req = urllib.request.Request(new_tab_url)
    with urllib.request.urlopen(req, timeout=5) as response:
        new_result = response.read().decode()
        print(f'DEBUG: New tab response: {new_result}', file=sys.stderr)
        
        if new_result and ('id' in new_result or 'webSocketDebuggerUrl' in new_result):

            try:
                close_url = f'http://localhost:{debug_port}/json/close/{tab_id}'
                close_req = urllib.request.Request(close_url)
                urllib.request.urlopen(close_req, timeout=2)
                print(f'DEBUG: Closed old tab {tab_id}', file=sys.stderr)
            except:
                pass
            print('SUCCESS')
        else:
            raise Exception('New tab creation failed')
            
except Exception as e:
    print(f'DEBUG: Method 1a failed: {e}', file=sys.stderr)
    

    try:

        activate_url = f'http://localhost:{debug_port}/json/activate/{tab_id}'
        print(f'DEBUG: Activating tab: {activate_url}', file=sys.stderr)
        
        req = urllib.request.Request(activate_url)
        urllib.request.urlopen(req, timeout=5)
        
        import time
        time.sleep(0.2)
        


        js_code = f'window.location.href="{url_to_navigate}";'
        encoded_js = urllib.parse.quote(js_code)
        eval_url = f'http://localhost:{debug_port}/json/runtime/evaluate?expression={encoded_js}'
        print(f'DEBUG: Runtime evaluate: {eval_url}', file=sys.stderr)
        
        req = urllib.request.Request(eval_url)
        with urllib.request.urlopen(req, timeout=5) as response:
            eval_result = response.read().decode()
            print(f'DEBUG: Evaluate response: {eval_result}', file=sys.stderr)
            print('SUCCESS')
            
    except Exception as e2:
        print(f'DEBUG: Method 1b failed: {e2}', file=sys.stderr)
        

        try:
            simple_url = f'http://localhost:{debug_port}/json/new'
            print(f'DEBUG: Simple new tab: {simple_url}', file=sys.stderr)
            
            req = urllib.request.Request(simple_url, method='PUT')
            req.add_header('Content-Type', 'text/plain')
            
            with urllib.request.urlopen(req, data=url_to_navigate.encode('utf-8'), timeout=5) as response:
                simple_result = response.read().decode()
                print(f'DEBUG: Simple response: {simple_result}', file=sys.stderr)
                
                if simple_result and ('id' in simple_result):

                    import json as json_module
                    new_tab_data = json_module.loads(simple_result)
                    new_tab_id = new_tab_data['id']
                    

                    try:
                        close_url = f'http://localhost:{debug_port}/json/close/{tab_id}'
                        close_req = urllib.request.Request(close_url)
                        urllib.request.urlopen(close_req, timeout=2)
                        print(f'DEBUG: Closed old tab {tab_id}', file=sys.stderr)
                    except:
                        pass
                    

                    try:
                        print(f'DEBUG: Attempting to import websocket library', file=sys.stderr)
                        import websocket
                        print(f'DEBUG: WebSocket library imported successfully', file=sys.stderr)
                        
                        ws_url = f'ws://localhost:{debug_port}/devtools/page/{new_tab_id}'
                        print(f'DEBUG: Using WebSocket to navigate new tab: {ws_url}', file=sys.stderr)
                        
                        def on_open(ws):
                            print(f'DEBUG: WebSocket connection opened', file=sys.stderr)

                            enable_cmd = {
                                'id': 1,
                                'method': 'Page.enable'
                            }
                            print(f'DEBUG: Sending Page.enable command', file=sys.stderr)
                            ws.send(json_module.dumps(enable_cmd))
                            

                            nav_cmd = {
                                'id': 2,
                                'method': 'Page.navigate',
                                'params': {'url': url_to_navigate}
                            }
                            print(f'DEBUG: Sending Page.navigate command to {url_to_navigate}', file=sys.stderr)
                            ws.send(json_module.dumps(nav_cmd))
                        
                        def on_error(ws, error):
                            print(f'DEBUG: WebSocket error: {error}', file=sys.stderr)

                        
                        def on_close(ws, close_status_code, close_msg):
                            print(f'DEBUG: WebSocket closed: {close_status_code} {close_msg}', file=sys.stderr)
                        
                        def on_message(ws, message):
                            result = json_module.loads(message)
                            print(f'DEBUG: WebSocket response: {result}', file=sys.stderr)
                            if 'result' in result and result.get('id') == 2:

                                print('SUCCESS')
                                ws.close()
                            elif 'error' in result:
                                print('FAILED')
                                ws.close()
                        
                        print(f'DEBUG: Creating WebSocket connection', file=sys.stderr)
                        ws = websocket.WebSocketApp(ws_url, 
                            on_open=on_open, 
                            on_message=on_message,
                            on_error=on_error,
                            on_close=on_close)
                        print(f'DEBUG: Starting WebSocket connection', file=sys.stderr)
                        ws.run_forever()
                        print(f'DEBUG: WebSocket run_forever completed', file=sys.stderr)
                        

                        raise Exception('WebSocket navigation failed')
                        
                    except ImportError:
                        print(f'DEBUG: WebSocket library not available', file=sys.stderr)

                        try:

                            time.sleep(0.5)
                            

                            nav_url = f'http://localhost:{debug_port}/json/runtime/evaluate'
                            nav_data = {
                                'expression': f'window.location.href = \"{url_to_navigate}\";'
                            }
                            
                            import json as json_mod
                            data = json_mod.dumps(nav_data).encode('utf-8')
                            req = urllib.request.Request(nav_url, data=data, headers={'Content-Type': 'application/json'})
                            
                            with urllib.request.urlopen(req, timeout=5) as response:
                                result = response.read().decode()
                                print(f'DEBUG: HTTP navigation response: {result}', file=sys.stderr)
                                if result and not 'error' in result.lower():
                                    print('SUCCESS')
                                else:
                                    print('FAILED')
                        except Exception as fallback_error:
                            print(f'DEBUG: HTTP fallback failed: {fallback_error}', file=sys.stderr)
                            print('FAILED')
                    except Exception as ws_error:
                        print(f'DEBUG: WebSocket error: {ws_error}', file=sys.stderr)
                        print(f'DEBUG: Trying HTTP fallback method', file=sys.stderr)

                        try:

                            import time
                            time.sleep(0.5)
                            

                            nav_url = f'http://localhost:{debug_port}/json/runtime/evaluate'
                            nav_data = {
                                'expression': f'window.location.href = \"{url_to_navigate}\";'
                            }
                            
                            import json as json_mod
                            data = json_mod.dumps(nav_data).encode('utf-8')
                            req = urllib.request.Request(nav_url, data=data, headers={'Content-Type': 'application/json'})
                            
                            with urllib.request.urlopen(req, timeout=5) as response:
                                result = response.read().decode()
                                print(f'DEBUG: HTTP navigation response: {result}', file=sys.stderr)
                                if result and not 'error' in result.lower():
                                    print('SUCCESS')
                                else:
                                    print('FAILED')
                        except Exception as fallback_error:
                            print(f'DEBUG: HTTP fallback failed: {fallback_error}', file=sys.stderr)
                            print('FAILED')
                else:
                    raise Exception('Simple method failed')
                    
        except Exception as e3:
            print(f'DEBUG: Method 1c failed: {e3}', file=sys.stderr)
    

print('FAILED')
" 2>&1)
                unset NAVIGATE_URL
                
                log_debug "Navigation result: $nav_result"
                

                if echo "$nav_result" | grep -q "SUCCESS"; then
                    log_info "Successfully navigated browser to: $url"
                    return 0
                fi
                
                log_warn "All DevTools navigation methods failed"
                return 1
            else
                log_warn "Could not get tab information from DevTools"
            fi
        fi
    fi
    

    log_warn "Could not navigate via DevTools, restarting browser"
    start_browser_process "$url"
}

add_playlist_url() {
    local url="$1"
    local display_time="${2:-$DEFAULT_DISPLAY_TIME}"
    local title="${3:-}"
    local mode="${4:-add}"
    
    if [[ -z "$url" ]]; then
        log_error "URL is required"
        return 1
    fi
    
    if ! validate_url "$url"; then
        log_error "Invalid URL provided"
        return 1
    fi
    
    if ! validate_display_time "$display_time"; then
        log_error "Invalid display time provided"
        return 1
    fi
    

    if [[ -z "$title" ]]; then
        title=$(echo "$url" | sed -E 's|^https?://([^/]+).*|\1|')
    fi
    
    backup_config
    

    python3 -c "
import json

try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
except:
    data = {}
    
if 'playlist' not in data:
    data['playlist'] = {'enabled': False, 'default_display_time': 30, 'urls': []}

new_url = {
    'url': '$url',
    'display_time': int('$display_time'),
    'title': '$title'
}

if '$mode' == 'replace':
    data['playlist']['urls'] = [new_url]
    print('Replaced playlist with new URL: $url')
else:
    data['playlist']['urls'].append(new_url)
    print('Added URL to playlist: $url')


print(f'Total URLs in playlist: {len(data[\"playlist\"][\"urls\"])}')
print(f'Playlist enabled: {data[\"playlist\"].get(\"enabled\", False)}')

with open('$CONFIG_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || {
        log_error "Failed to add URL to playlist"
        return 1
    }
    
    log_info "Added URL to playlist: $url (${display_time}s)"
}

remove_playlist_url() {
    local index="$1"
    
    if [[ -z "$index" ]] || [[ ! "$index" =~ ^[0-9]+$ ]]; then
        log_error "Valid URL index required"
        return 1
    fi
    
    backup_config
    
    local config
    config=$(get_playlist_config)
    
    python3 -c "
import json
import sys


with open('$CONFIG_FILE', 'r') as f:
    full_config = json.load(f)


playlist_config = json.loads('''$config''')
urls = playlist_config.get('urls', [])

if $index < len(urls):
    removed = urls.pop($index)
    print(f\"Removed: {removed.get('title', 'Unknown')} - {removed.get('url', '')}\")


    playlist_config['urls'] = urls
    full_config['playlist'] = playlist_config

    with open('$CONFIG_FILE', 'w') as f:
        json.dump(full_config, f, indent=2)
    sys.exit(0)
else:
    print(f\"Index $index out of range (0-{len(urls)-1})\")
    sys.exit(1)
" || {
        log_error "Failed to remove URL from playlist"
        return 1
    }
}

enable_playlist() {
    backup_config
    
    local config
    config=$(get_playlist_config)
    
    python3 -c "
import json


with open('$CONFIG_FILE', 'r') as f:
    full_config = json.load(f)


playlist_config = json.loads('''$config''')
playlist_config['enabled'] = True
full_config['playlist'] = playlist_config


with open('$CONFIG_FILE', 'w') as f:
    json.dump(full_config, f, indent=2)
" || {
        log_error "Failed to enable playlist"
        return 1
    }
    
    log_info "Playlist mode enabled"


    echo "0" > "/tmp/kiosk-playlist-index"


    sleep 1


    if [[ ! -f "/tmp/kiosk-playlist-cycling.pid" ]] || ! kill -0 $(cat "/tmp/kiosk-playlist-cycling.pid" 2>/dev/null) 2>/dev/null; then
        log_info "Starting playlist cycling service..."
        start_playlist_cycling_service
    else
        log_info "Playlist cycling service already running"
    fi
}

disable_playlist() {
    backup_config
    
    local config
    config=$(get_playlist_config)
    
    python3 -c "
import json


with open('$CONFIG_FILE', 'r') as f:
    full_config = json.load(f)


playlist_config = json.loads('''$config''')
playlist_config['enabled'] = False
full_config['playlist'] = playlist_config


with open('$CONFIG_FILE', 'w') as f:
    json.dump(full_config, f, indent=2)
" || {
        log_error "Failed to disable playlist"
        return 1
    }
    

    if [[ -f "/tmp/kiosk-playlist-cycling.pid" ]]; then
        local cycling_pid
        cycling_pid=$(cat "/tmp/kiosk-playlist-cycling.pid" 2>/dev/null)
        if [[ -n "$cycling_pid" ]] && kill -0 "$cycling_pid" 2>/dev/null; then
            log_info "Stopping playlist cycling service (PID: $cycling_pid)..."
            kill "$cycling_pid" 2>/dev/null
            sleep 1
        fi
        rm -f "/tmp/kiosk-playlist-cycling.pid"
    fi


    rm -f "/tmp/kiosk-playlist-index" 2>/dev/null || true

    log_info "Playlist mode disabled"
}

show_playlist() {
    local config
    config=$(get_playlist_config)
    
    local enabled
    enabled=$(is_playlist_enabled)
    
    echo "========================================"
    echo "         PLAYLIST CONFIGURATION"
    echo "========================================"
    echo -e "Status: $(if [[ "$enabled" == "true" ]]; then echo -e "${GREEN}ENABLED${NC}"; else echo -e "${RED}DISABLED${NC}"; fi)"
    echo
    
    local urls_info
    urls_info=$(get_playlist_urls)
    
    if [[ -z "$urls_info" ]]; then
        echo "No URLs in playlist"
        echo
        echo "Add URLs with: kiosk playlist-add <URL> [display_time] [title]"
    else
        echo "URLs in playlist:"
        echo
        
        local current_index=0
        if [[ -f "/tmp/kiosk-playlist-index" ]] && [[ "$enabled" == "true" ]]; then
            current_index=$(cat "/tmp/kiosk-playlist-index" 2>/dev/null || echo "0")
        fi
        
        local index=0
        while IFS= read -r url_info; do
            local url title display_time
            url=$(echo "$url_info" | cut -d'|' -f2)
            display_time=$(echo "$url_info" | cut -d'|' -f3)
            title=$(echo "$url_info" | cut -d'|' -f4)
            
            local marker=""
            if [[ $index -eq $current_index ]] && [[ "$enabled" == "true" ]]; then
                marker=" ${GREEN}[CURRENT]${NC}"
            fi
            
            echo -e "  [$index] $title${marker}"
            echo "       URL: $url"
            echo "       Display Time: ${display_time}s"
            echo
            
            index=$((index + 1))
        done <<< "$urls_info"
        
        echo "Commands:"
        echo "  kiosk playlist-add <URL> [time] [title]  - Add URL"
        echo "  kiosk playlist-remove <index>           - Remove URL"
        echo "  kiosk playlist-enable                   - Enable cycling through URLs"
        echo "  kiosk playlist-disable                  - Disable cycling through URLs"
    fi
    
    echo "========================================"
}

backup_config() {
    local backup_dir="$INSTALL_DIR/backups"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    
    mkdir -p "$backup_dir" 2>/dev/null || return 1
    
    for config in "$CONFIG_FILE"; do
        if [[ -f "$config" ]]; then
            local filename=$(basename "$config")

            filename=$(sanitize_path "$filename")
            local safe_backup_path="$backup_dir/${filename}.${timestamp}"
            cp "$config" "$safe_backup_path" 2>/dev/null || {
                log_warn "Failed to backup: $config"
                continue
            }
            log_debug "Backed up: $config"
        fi
    done
    

    find "$backup_dir" -type f -name "*.20*" | sort -r | tail -n +11 | xargs rm -f 2>/dev/null || true
    
    log_info "Configuration backed up to: $backup_dir"
}

restore_config() {
    local backup_dir="$INSTALL_DIR/backups"
    local config_name="$1"
    
    if [[ -z "$config_name" ]]; then
        log_error "Config name required for restore"
        return 1
    fi
    

    local latest_backup

    local safe_config_name=$(sanitize_path "$config_name")
    latest_backup=$(find "$backup_dir" -name "${safe_config_name}.*" -type f | sort -r | head -1)
    
    if [[ -z "$latest_backup" ]]; then
        log_error "No backup found for: $config_name"
        return 1
    fi
    
    local target_file
    case "$config_name" in
        "kiosk_url.txt")
            target_file="$CONFIG_FILE"
            ;;
        "api_config.json")
            target_file="$CONFIG_FILE"
            ;;
        "rotation_config.txt")
            target_file="$CONFIG_FILE"
            ;;
        "playlist_config.json")
            target_file="$CONFIG_FILE"
            ;;
        *)
            log_error "Unknown config name: $config_name"
            return 1
            ;;
    esac
    
    if cp "$latest_backup" "$target_file"; then
        log_info "Restored $config_name from: $latest_backup"
        return 0
    else
        log_error "Failed to restore $config_name"
        return 1
    fi
}


monitor_browser_health() {
    local max_memory_kb=$BROWSER_MEMORY_LIMIT
    local restart_count=0

    while true; do
        sleep $HEALTH_CHECK_INTERVAL
        

        if ! pgrep -f chromium >/dev/null; then
            log_warn "Browser not running, attempting restart..."
            recover_browser
            ((restart_count++))
            
            if [[ $restart_count -ge $BROWSER_RESTART_THRESHOLD ]]; then
                log_critical "Browser restarted $restart_count times, may need manual intervention"
                save_debug_state
                restart_count=0
            fi
            continue
        fi
        

        local browser_memory
        browser_memory=$(get_browser_memory_kb)
        
        # Check memory usage (crash detection removed - memory management is sufficient)
        if [[ $browser_memory -gt $max_memory_kb ]]; then
            log_warn "Browser memory usage high: ${browser_memory}KB > ${max_memory_kb}KB, restarting..."
            recover_browser
            ((restart_count++))
        else
            # Simple monitoring - just log current memory usage
            log_debug "Browser memory within limits: ${browser_memory}KB"
        fi
        

        if ! timeout 5 xdpyinfo -display :0 >/dev/null 2>&1; then
            log_warn "X server not responsive, attempting display recovery..."
            recover_display
        fi

        # Memory-based browser management only

        if [[ $(($(date +%s) % 300)) -eq 0 ]]; then
            log_debug "Health check: Browser running, Memory: ${browser_memory}KB"
        fi
    done
}


start_browser_with_monitoring() {
    local url="$1"
    
    if [[ -z "$url" ]]; then
        url=$(get_url)
    fi
    
    validate_url "$url" || {
        log_error "Cannot start browser with invalid URL: $url"
        return 1
    }
    
    log_info "Starting browser with monitoring for URL: $url"
    

    monitor_browser_health &
    local monitor_pid=$!
    echo $monitor_pid > /tmp/kiosk-monitor.pid
    

    start_browser_process "$url"
}

start_browser_process() {
    local url="$1"
    

    pkill -f chromium 2>/dev/null || true
    sleep 2
    pkill -9 -f chromium 2>/dev/null || true
    

    rm -rf /tmp/chromium-kiosk 2>/dev/null || true
    

    local x_ready=false
    for i in {1..30}; do
        if timeout 3 xdpyinfo -display :0 >/dev/null 2>&1; then
            x_ready=true
            break
        fi
        log_debug "Waiting for X server... ($i/30)"
        sleep 1
    done
    
    if [[ "$x_ready" != true ]]; then
        log_error "X server not ready after 30 seconds"
        return 1
    fi
    

    local browser_cmd
    if [[ "$IS_ARM" == true ]]; then
        browser_cmd="$CHROMIUM_PATH --no-first-run --no-default-browser-check --disable-default-apps --disable-popup-blocking --disable-translate --disable-background-timer-throttling --disable-renderer-backgrounding --disable-device-discovery-notifications --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --noerrdialogs --kiosk --start-maximized --disable-gpu-sandbox --use-gl=egl --enable-gpu-rasterization --disable-web-security --disable-features=TranslateUI --no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage --memory-pressure-off --max_old_space_size=1024 --js-flags=--max-old-space-size=1024 --aggressive-cache-discard --disable-background-networking --site-per-process --disable-site-isolation-trials --display=:0 --remote-debugging-port=$DEBUG_PORT --remote-allow-origins=* --user-data-dir=/tmp/chromium-kiosk"
        
        if [[ "$IS_RPI" == true ]]; then
            browser_cmd="$browser_cmd --disable-features=VizDisplayCompositor --disable-smooth-scrolling --disable-2d-canvas-clip-aa --disable-canvas-aa --disable-accelerated-2d-canvas"
        fi
    else
        browser_cmd="$CHROMIUM_PATH --no-first-run --no-default-browser-check --disable-default-apps --disable-popup-blocking --disable-translate --disable-background-timer-throttling --disable-renderer-backgrounding --disable-device-discovery-notifications --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --noerrdialogs --kiosk --start-maximized --disable-gpu --disable-software-rasterizer --disable-web-security --disable-features=TranslateUI,VizDisplayCompositor --disable-ipc-flooding-protection --no-sandbox --disable-setuid-sandbox --force-device-scale-factor=1 --memory-pressure-off --max_old_space_size=1024 --js-flags=--max-old-space-size=1024 --aggressive-cache-discard --disable-background-networking --site-per-process --disable-site-isolation-trials --display=:0 --remote-debugging-port=$DEBUG_PORT --remote-allow-origins=* --user-data-dir=/tmp/chromium-kiosk"
    fi
    

    browser_cmd_array=($browser_cmd)
    browser_cmd_array+=("$url")

    log_debug "Starting browser: ${browser_cmd_array[*]}"


    "${browser_cmd_array[@]}" &
    local browser_pid=$!
    echo $browser_pid > /tmp/kiosk-browser.pid
    

    sleep 5
    

    if ! kill -0 $browser_pid 2>/dev/null; then
        log_error "Browser failed to start (PID $browser_pid)"
        return 1
    fi
    
    log_info "Browser started successfully (PID $browser_pid)"
    return 0
}


check_system_health() {
    local issues=()
    

    local disk_usage
    disk_usage=$(df /opt/kiosk | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        issues+=("High disk usage: ${disk_usage}%")
    fi
    

    local mem_usage
    mem_usage=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100)}')
    if [[ $mem_usage -gt 90 ]]; then
        issues+=("High memory usage: ${mem_usage}%")
    fi
    

    for service in kiosk.service kiosk-api.service; do
        if ! systemctl is-active "$service" >/dev/null 2>&1; then
            issues+=("Service not running: $service")
        fi
    done
    

    if ! timeout 5 xdpyinfo -display :0 >/dev/null 2>&1; then
        issues+=("X server not responsive")
    fi
    

    if ! pgrep -f chromium >/dev/null; then
        issues+=("Browser not running")
    fi
    

    if [[ ! -f "$CONFIG_FILE" ]]; then
        issues+=("Missing config file: $(basename "$CONFIG_FILE")")
    fi
    
    return ${#issues[@]}
}

get_system_health_report() {
    local issues=()
    

    echo "=== KIOSK SYSTEM HEALTH REPORT ==="
    echo "Timestamp: $(date)"
    echo "Architecture: $ARCH"
    [[ "$IS_RPI" == true ]] && echo "Raspberry Pi: Yes"
    echo
    

    echo "=== DISK USAGE ==="
    df -h / 2>/dev/null || echo "Disk info unavailable"
    echo
    

    echo "=== MEMORY USAGE ==="
    free -h
    echo
    

    echo "=== SERVICES ==="
    for service in kiosk.service kiosk-api.service; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            echo "$service: RUNNING"
        else
            echo "$service: STOPPED"
            issues+=("$service not running")
        fi
    done
    echo
    

    echo "=== PROCESSES ==="
    echo "X Server: $(pgrep Xorg >/dev/null && echo "RUNNING" || echo "STOPPED")"
    echo "Browser: $(pgrep -f chromium >/dev/null && echo "RUNNING" || echo "STOPPED")"
    echo "Window Manager: $(pgrep openbox >/dev/null && echo "RUNNING" || echo "STOPPED")"
    echo
    

    if pgrep -f chromium >/dev/null; then
        echo "=== BROWSER MEMORY ==="
        local browser_memory
        browser_memory=$(get_browser_memory_kb)
        echo "Total memory: ${browser_memory}KB"
        echo "Limit: ${BROWSER_MEMORY_LIMIT}KB"
        if [[ $browser_memory -gt $BROWSER_MEMORY_LIMIT ]]; then
            echo "Status: HIGH (exceeds limit)"
            issues+=("Browser memory usage high")
        else
            echo "Status: OK"
        fi
        echo
    fi
    

    echo "=== CONFIGURATION ==="
    echo "URL: $(get_url 2>/dev/null || echo "ERROR")"
    echo "Rotation: $(get_rotation 2>/dev/null || echo "ERROR")"
    echo "API Key: $(get_api_key 2>/dev/null | cut -c1-8)..."
    echo
    

    echo "=== NETWORK ==="
    local ip_addr
    ip_addr=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    echo "IP Address: ${ip_addr:-"Unknown"}"
    
    if command -v curl >/dev/null; then
        echo -n "Internet: "
        if timeout 5 curl -s http://google.com >/dev/null; then
            echo "OK"
        else
            echo "FAILED"
            issues+=("No internet connectivity")
        fi
    fi
    echo
    

    if [[ ${#issues[@]} -gt 0 ]]; then
        echo "=== ISSUES DETECTED ==="
        for issue in "${issues[@]}"; do
            echo "- $issue"
        done
        echo
        echo "Health check detected ${#issues[@]} issue(s). Review above for details."
    else
        echo "=== STATUS: ALL OK ==="
        echo
    fi
    

    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This command must be run as root!"
        log_error "Please run: sudo kiosk $1"
        exit 1
    fi
}

generate_api_key() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}



create_kiosk_user() {
    log_info "Checking for user '$KIOSK_USER'..."
    
    if id "$KIOSK_USER" &>/dev/null; then
        log_info "User '$KIOSK_USER' already exists"
        return 0
    fi
    
    log_info "Creating user '$KIOSK_USER'..."
    useradd -m -s /bin/bash -G audio,video,users "$KIOSK_USER" || {
        log_error "Failed to create user '$KIOSK_USER'"
        return 1
    }
    
    mkdir -p "/home/$KIOSK_USER/.config"
    chown -R "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER"
    
    log_info "User '$KIOSK_USER' created successfully"
}

install_system_packages() {
    log_info "Updating package lists..."
    apt-get update || {
        log_error "Failed to update package lists"
        return 1
    }
    
    log_info "Installing base system packages..."
    apt-get install -f -y
    
    for package in "${SYSTEM_PACKAGES[@]}"; do
        log_info "Installing $package..."
        apt-get install -y --no-install-recommends "$package" || log_warn "Failed to install $package"
    done
    
    if [[ "$IS_ARM" == true ]]; then
        log_info "Installing ARM-specific packages..."
        install_arm_packages
    else
        log_info "Installing x86-specific packages..."
        install_x86_packages
    fi
    
    apt-get autoremove -y
    apt-get autoclean
    
    log_info "System packages installation completed"
}

install_arm_packages() {

    for package in "${ARM_PACKAGES[@]}"; do
        log_info "Installing ARM package: $package..."
        if ! apt-get install -y --no-install-recommends "$package"; then
            case $package in
                "chromium-browser")
                    if ! apt-get install -y --no-install-recommends chromium; then
                        log_warn "Chromium not available via apt, trying snap..."
                        snap install chromium || log_error "Failed to install chromium"
                    fi
                    ;;
                *)
                    log_warn "Failed to install ARM package: $package"
                    ;;
            esac
        fi
    done


    if [[ "$IS_RPI" == true ]]; then
        log_info "Installing Raspberry Pi specific packages for desktop functionality..."


        if command -v raspi-config >/dev/null; then
            log_info "Configuring Raspberry Pi GPU memory split..."
            echo "gpu_mem=128" >> /boot/config.txt 2>/dev/null || true
        fi

        for package in "${RPI_PACKAGES[@]}"; do
            log_info "Installing Raspberry Pi package: $package..."
            if ! apt-get install -y --no-install-recommends "$package"; then
                case $package in
                    "lxde-core")
                        log_warn "LXDE not available, trying alternative lightweight desktop..."
                        apt-get install -y --no-install-recommends openbox-lxde-session || log_warn "Failed to install alternative desktop"
                        ;;
                    "omxplayer")
                        log_warn "OMXPlayer not available (deprecated on newer Pi OS versions)"
                        ;;
                    *)
                        log_warn "Failed to install Raspberry Pi package: $package"
                        ;;
                esac
            fi
        done
    fi
}

install_x86_packages() {
    for package in "${X86_PACKAGES[@]}"; do
        log_info "Installing x86 package: $package..."
        if ! apt-get install -y --no-install-recommends "$package"; then
            case $package in
                "chromium-browser")
                    if ! apt-get install -y --no-install-recommends chromium; then
                        log_warn "Chromium not available via apt, trying snap..."
                        snap install chromium || log_error "Failed to install chromium"
                    fi
                    ;;
                "xserver-xorg-video-intel"|"xserver-xorg-video-nouveau"|"xserver-xorg-video-radeon")
                    log_warn "GPU driver not available: $package (hardware not present or driver unavailable)"
                    ;;
                "lxde-core")
                    log_warn "LXDE not available, trying alternative lightweight desktop..."
                    apt-get install -y --no-install-recommends openbox-lxde-session || log_warn "Failed to install alternative desktop"
                    ;;
                "vainfo")
                    log_warn "Video acceleration info tool not available"
                    ;;
                *)
                    log_warn "Failed to install x86 package: $package"
                    ;;
            esac
        fi
    done
}

install_python_packages() {
    log_info "Installing Python packages..."
    
    for package in "${PYTHON_PACKAGES[@]}"; do
        log_info "Installing Python package: $package"
        python3 -m pip install --break-system-packages "$package" || {
            log_error "Failed to install Python package: $package"
            return 1
        }
    done
    
    log_info "Python packages installation completed"
}

detect_chromium_path() {
    local possible_paths=()
    
    if [[ "$IS_ARM" == true ]]; then
        possible_paths=(
            "/usr/bin/chromium-browser"
            "/usr/bin/chromium"
            "/snap/bin/chromium"
        )
    else
        possible_paths=(
            "/usr/bin/chromium-browser"
            "/usr/bin/chromium"
            "/snap/bin/chromium"
        )
    fi
    
    for path in "${possible_paths[@]}"; do
        if [[ -x "$path" ]]; then
            CHROMIUM_PATH="$path"
            log_info "Found browser at: $path"
            return 0
        fi
    done
    
    if command -v chromium &> /dev/null; then
        CHROMIUM_PATH=$(which chromium)
        log_info "Found Chromium via which: $CHROMIUM_PATH"
        return 0
    fi
    
    log_error "No supported browser found!"
    return 1
}

create_directories() {
    log_info "Creating directory structure..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "/etc/X11/xorg.conf.d"
    mkdir -p "/etc/systemd/system/getty@tty1.service.d"
}

create_api_config() {
    log_info "Creating API configuration..."
    
    local api_key
    api_key=$(generate_api_key)
    
    cat > "$API_CONFIG_FILE" << EOF
{
  "api_key": "$api_key",
  "require_auth": true
}
EOF
    
    chmod 644 "$API_CONFIG_FILE"
    
    log_info "API configuration created"
}

create_default_configs() {
    log_info "Creating default configurations..."
    
    create_default_config
    chmod 644 "$CONFIG_FILE"
}

disable_screen_blanking() {
    log_info "Disabling screen blanking..."
    
    cat > /etc/X11/xorg.conf.d/10-screen.conf << 'EOF'
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "Extensions"
    Option "DPMS" "Disable"
EndSection
EOF
    
    cat > "$INSTALL_DIR/disable_blanking.sh" << 'EOF'
#!/bin/bash
export DISPLAY=:0
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true
EOF
    
    chmod +x "$INSTALL_DIR/disable_blanking.sh"
    
    log_info "Screen blanking disabled"
}

create_usage_examples() {
    log_info "Creating usage examples file..."


    local api_key=$(get_config_value "api.api_key" 2>/dev/null || echo "your-api-key-here")
    local ip_addr=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "your-kiosk-ip")


    cat > "$INSTALL_DIR/USAGE_EXAMPLES.md" << EOF
Kiosk API Gateway - Complete Reference

System IP: $ip_addr
API Key: $api_key

MEMORY MANAGEMENT:
- Dynamic memory limits based on system RAM
- Your system: $(free -h | awk '/^Mem:/ {print $2}') RAM
- Browser memory limit: Auto-calculated for optimal performance
- Memory monitoring with automatic browser restart when needed

BROWSER MANAGEMENT:
- Memory-based browser restarts (much faster than page refreshing)
- Dynamic memory limits based on system RAM
- No forced page refreshing - clean, simple operation
- Fast browser-only restart (no service restart needed)

===============================================
CLI Commands
===============================================
  kiosk status
  kiosk set-url http://your-site.com        # Memory management handles browser health
  kiosk get-url
  kiosk set-display-orientation left
  kiosk get-rotation
  kiosk playlist
  kiosk playlist-add http://site.com 60 "Title"
  kiosk playlist-remove 1
  kiosk playlist-enable
  kiosk playlist-disable
  sudo kiosk playlist-clear
  sudo kiosk restart
  sudo kiosk start
  sudo kiosk stop
  kiosk logs

===============================================
API Endpoints - Simple Commands
===============================================


curl "http://$ip_addr/status?api_key=$api_key"
curl "http://$ip_addr/api-info?api_key=$api_key"


curl -X POST "http://$ip_addr/set-url?api_key=$api_key&url=http://google.com"
curl "http://$ip_addr/get-url?api_key=$api_key"


curl -X POST "http://$ip_addr/set-display-orientation?api_key=$api_key&orientation=left"
curl "http://$ip_addr/get-rotation?api_key=$api_key"


curl "http://$ip_addr/playlist?api_key=$api_key"
curl -X POST "http://$ip_addr/playlist-add?api_key=$api_key&url=http://site.com&duration=60"
curl -X POST "http://$ip_addr/playlist-remove?api_key=$api_key&index=1"
curl -X POST "http://$ip_addr/playlist-enable?api_key=$api_key"
curl -X POST "http://$ip_addr/playlist-disable?api_key=$api_key"
curl -X POST "http://$ip_addr/playlist-clear?api_key=$api_key"


curl -X POST "http://$ip_addr/start?api_key=$api_key"
curl -X POST "http://$ip_addr/stop?api_key=$api_key"
curl -X POST "http://$ip_addr/restart?api_key=$api_key"

===============================================
API Endpoints - Advanced JSON Commands
===============================================


curl -X POST "http://$ip_addr/set-url?api_key=$api_key" \\
     -H "Content-Type: application/json" \\
     -d '{"url": "http://dashboard.example.com"}'


curl -X POST "http://$ip_addr/playlist-add?api_key=$api_key" \\
     -H "Content-Type: application/json" \\
     -d '{"url": "http://site.com", "duration": 120, "title": "My Site"}'


curl -X POST "http://$ip_addr/playlist-replace?api_key=$api_key" \\
     -H "Content-Type: application/json" \\
     -d '{
       "urls": [
         {"url": "http://google.com", "duration": 30, "title": "Google"},
         {"url": "http://github.com", "duration": 45, "title": "GitHub"},
         {"url": "http://stackoverflow.com", "duration": 60, "title": "Stack Overflow"}
       ]
     }'


curl -X POST "http://$ip_addr/set-display-orientation?api_key=$api_key" \\
     -H "Content-Type: application/json" \\
     -d '{"orientation": "inverted"}'

===============================================
Response Examples
===============================================


{"success": true, "kiosk_running": true, "api_running": true, "current_url": "http://google.com"}


{"success": true, "url": "http://google.com"}


{"success": true, "playlist": [{"url": "http://site1.com", "duration": 30, "title": "Site 1"}]}


{"error": "Multiple URLs not allowed in set-url endpoint", "message": "Use playlist endpoints for multiple URLs"}

===============================================
Quick Start Examples
===============================================


curl -X POST "http://$ip_addr/set-url?api_key=$api_key&url=http://your-dashboard.com"


curl -X POST "http://$ip_addr/playlist-replace?api_key=$api_key" \\
     -H "Content-Type: application/json" \\
     -d '{
       "urls": [
         {"url": "http://site1.com", "duration": 45},
         {"url": "http://site2.com", "duration": 60},
         {"url": "http://site3.com", "duration": 30}
       ]
     }'
curl -X POST "http://$ip_addr/playlist-enable?api_key=$api_key"


curl "http://$ip_addr/status?api_key=$api_key"
curl "http://$ip_addr/playlist?api_key=$api_key"


curl -X POST "http://$ip_addr/set-display-orientation?api_key=$api_key&orientation=left"

EOF

    chmod 644 "$INSTALL_DIR/USAGE_EXAMPLES.md"

    log_info "Usage examples file created at $INSTALL_DIR/USAGE_EXAMPLES.md"
}

create_kiosk_script() {
    log_info "Creating kiosk startup script..."
    
    cat > "$INSTALL_DIR/start_kiosk.sh" << EOF
#!/bin/bash
set -e


if ! pgrep Xorg >/dev/null; then
    echo "Starting X server as root..."
    X :0 -nolisten tcp -noreset +extension GLX vt1 &
    sleep 3
    

    xhost +local: 2>/dev/null || true
    xhost +local:$KIOSK_USER 2>/dev/null || true
    chown $KIOSK_USER:$KIOSK_USER /tmp/.X11-unix/X0 2>/dev/null || true
    chmod 666 /tmp/.X11-unix/X0 2>/dev/null || true
fi

export DISPLAY=:0
export HOME=$INSTALL_DIR
cd $INSTALL_DIR


for i in {1..30}; do
    if xdpyinfo -display :0 >/dev/null 2>&1; then
        echo "X server is ready"
        break
    fi
    sleep 1
done


./disable_blanking.sh


if ! pgrep openbox >/dev/null; then
    echo "Starting Openbox..."
    openbox &
    sleep 2
fi


if ! pgrep unclutter >/dev/null; then
    echo "Starting unclutter..."
    unclutter -display :0 -idle 1 -root &
    sleep 1
fi


xsetroot -solid black 2>/dev/null || true


if [[ -f "$CONFIG_FILE" ]]; then
    ROTATION=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)

    orientation = data.get('display', {}).get('orientation', '')
    if orientation:
        print(orientation)
    else:
        print(data.get('kiosk', {}).get('rotation', 'normal'))
except:
    print('normal')
" 2>/dev/null)
else
    ROTATION="normal"
fi

if [[ "\$ROTATION" != "normal" ]]; then
    echo "Applying rotation: \$ROTATION"
    PRIMARY_DISPLAY=\$(xrandr --query | grep " connected" | head -1 | cut -d' ' -f1)
    if [[ -n "\$PRIMARY_DISPLAY" ]]; then
        xrandr --output "\$PRIMARY_DISPLAY" --rotate "\$ROTATION" 2>/dev/null || true
    fi
fi


if [[ -f "$CONFIG_FILE" ]]; then
    PLAYLIST_ENABLED=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    print('true' if data.get('playlist', {}).get('enabled', False) else 'false')
except:
    print('false')
" 2>/dev/null)
else
    PLAYLIST_ENABLED="false"
fi


pkill -f chromium 2>/dev/null || true
sleep 2

if [[ "\$PLAYLIST_ENABLED" == "true" ]]; then
    echo "Starting browser in playlist mode..."

    URL=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    urls = data.get('playlist', {}).get('urls', [])
    if urls:
        print(urls[0].get('url', 'http://example.com'))
    else:
        print('http://example.com')
except:
    print('http://example.com')
" 2>/dev/null)
    echo "Starting with URL: \$URL"
    

    echo "0" > /tmp/kiosk-playlist-index
else

    URL=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    print(data.get('kiosk', {}).get('url', 'http://example.com'))
except:
    print('http://example.com')
" 2>/dev/null)
    echo "Starting browser with single URL: \$URL"
fi


if [[ "$IS_ARM" == true ]]; then
    BROWSER_FLAGS="--no-first-run --no-default-browser-check --disable-default-apps --disable-popup-blocking --disable-translate --disable-background-timer-throttling --disable-renderer-backgrounding --disable-device-discovery-notifications --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --noerrdialogs --kiosk --start-maximized --disable-gpu-sandbox --use-gl=egl --enable-gpu-rasterization --disable-web-security --disable-features=TranslateUI --no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage --memory-pressure-off --max_old_space_size=1024 --js-flags=--max-old-space-size=1024 --aggressive-cache-discard --disable-background-networking --site-per-process --disable-site-isolation-trials --display=:0 --remote-debugging-port=$DEBUG_PORT --remote-allow-origins=* --user-data-dir=/tmp/chromium-kiosk"
    
    if [[ "$IS_RPI" == true ]]; then
        BROWSER_FLAGS="\$BROWSER_FLAGS --disable-features=VizDisplayCompositor --disable-smooth-scrolling --disable-2d-canvas-clip-aa --disable-canvas-aa --disable-accelerated-2d-canvas"
    fi
else
    BROWSER_FLAGS="--no-first-run --no-default-browser-check --disable-default-apps --disable-popup-blocking --disable-translate --disable-background-timer-throttling --disable-renderer-backgrounding --disable-device-discovery-notifications --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --noerrdialogs --kiosk --start-maximized --disable-gpu --disable-software-rasterizer --disable-web-security --disable-features=TranslateUI,VizDisplayCompositor --disable-ipc-flooding-protection --no-sandbox --disable-setuid-sandbox --force-device-scale-factor=1 --memory-pressure-off --max_old_space_size=1024 --js-flags=--max-old-space-size=1024 --aggressive-cache-discard --disable-background-networking --site-per-process --disable-site-isolation-trials --display=:0 --remote-debugging-port=$DEBUG_PORT --remote-allow-origins=* --user-data-dir=/tmp/chromium-kiosk"
fi


start_kiosk_browser() {
    local url="\$1"
    echo "Starting browser with URL: \$url"
    $CHROMIUM_PATH \$BROWSER_FLAGS "\$url" &
    BROWSER_PID=\$!
    echo \$BROWSER_PID > /tmp/kiosk-browser.pid
    echo "Browser started with PID: \$BROWSER_PID"
}

restart_kiosk_browser() {
    echo "Restarting browser..."

    # Get current browser PID
    local current_pid
    current_pid=\$(cat /tmp/kiosk-browser.pid 2>/dev/null || echo "")

    # Kill current browser gracefully
    if [[ -n "\$current_pid" ]] && kill -0 "\$current_pid" 2>/dev/null; then
        echo "Stopping browser PID: \$current_pid"
        kill -TERM "\$current_pid" 2>/dev/null || true
        sleep 2
        kill -KILL "\$current_pid" 2>/dev/null || true
    fi

    # Clean up any remaining chromium processes
    pkill -f "chromium.*user-data-dir=/tmp/chromium-kiosk" 2>/dev/null || true

    # Clear browser cache
    rm -rf /tmp/chromium-kiosk 2>/dev/null || true

    # Get current URL from config
    local current_url
    current_url=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    print(data.get('kiosk', {}).get('url', 'http://example.com'))
except:
    print('http://example.com')
" 2>/dev/null)

    # Restart browser
    start_kiosk_browser "\$current_url"
}

# Create restart signal handler
echo \$\$ > /tmp/kiosk-service.pid
trap restart_kiosk_browser USR1

start_kiosk_browser "\$URL"

# Start browser monitoring for memory management (single URL mode only)
if [[ "\$PLAYLIST_ENABLED" != "true" ]]; then
    echo "Starting browser memory monitoring..."
    (
        sleep 5  # Wait for browser to start

        # Source the main script functions
        source $INSTALL_DIR/kiosk-setup.sh

        # Start monitoring
        monitor_browser_health
    ) &
    MONITOR_PID=\$!
    echo \$MONITOR_PID > /tmp/kiosk-monitor.pid
    echo "Browser memory monitoring started (PID: \$MONITOR_PID)"
fi


if [[ "\$PLAYLIST_ENABLED" == "true" ]]; then
    echo "Starting playlist cycling service..."
    (
        sleep 10
        while true; do

            DISPLAY_TIME=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    urls = data.get('playlist', {}).get('urls', [])
    

    current_index = 0
    try:
        with open('/tmp/kiosk-playlist-index', 'r') as idx_file:
            current_index = int(idx_file.read().strip())
    except:
        pass
    
    if current_index < len(urls):
        display_time = urls[current_index].get('display_time', data.get('playlist', {}).get('default_display_time', $DEFAULT_DISPLAY_TIME))
        print(display_time)
    else:
        print($DEFAULT_DISPLAY_TIME)
except:
    print($DEFAULT_DISPLAY_TIME)
" 2>/dev/null)
            
            echo "Waiting \${DISPLAY_TIME}s for current URL..."
            sleep "\$DISPLAY_TIME"
            

            PLAYLIST_INFO=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    enabled = data.get('playlist', {}).get('enabled', False)
    url_count = len(data.get('playlist', {}).get('urls', []))
    print(f'{enabled}|{url_count}')
except:
    print('false|0')
" 2>/dev/null)
            
            STILL_ENABLED=\$(echo "\$PLAYLIST_INFO" | cut -d'|' -f1)
            URL_COUNT=\$(echo "\$PLAYLIST_INFO" | cut -d'|' -f2)
            
            if [[ "\$STILL_ENABLED" != "True" ]] || [[ "\$URL_COUNT" -le 1 ]]; then
                echo "Playlist disabled or single URL mode, stopping rotation"
                break
            fi
            

            python3 -c "
import json
import subprocess

current_index = 0
try:
    with open('/tmp/kiosk-playlist-index', 'r') as f:
        current_index = int(f.read().strip())
except:
    pass

try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    total_urls = len(data.get('playlist', {}).get('urls', []))
    
    if total_urls > 1:

        current_index = (current_index + 1) % total_urls
        
        with open('/tmp/kiosk-playlist-index', 'w') as f:
            f.write(str(current_index))
            

        next_url = data['urls'][current_index]['url']
        print(f'Navigating to: {next_url}')
        

        try:
            subprocess.run(['curl', '-s', '-X', 'POST', 
                          'http://localhost:$DEBUG_PORT/json/runtime/evaluate',
                          '-H', 'Content-Type: application/json',
                          '-d', f'{{\"expression\": \"window.location.href = \\'{next_url}\\'\"}}'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except:
            pass
except Exception as e:
    print(f'Error in playlist cycling: {e}')
"
        done
    ) &
    echo \$! > /tmp/kiosk-playlist-cycling.pid
fi


wait \$BROWSER_PID
EOF
    
    chmod +x "$INSTALL_DIR/start_kiosk.sh"
}

create_simple_api() {
    log_info "Creating Kiosk Command API Gateway..."

    cat > "$INSTALL_DIR/simple_api.py" << 'EOF'
#!/usr/bin/env python3
import os
import sys
import json
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import threading
import time

CONFIG_FILE = "/opt/kiosk/kiosk.json"
KIOSK_SCRIPT = "/opt/kiosk/kiosk-setup.sh"

def load_config():
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except:
        import secrets
        import string


        api_key = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32))

        default_config = {
            "kiosk": {"url": "http://example.com"},
            "display": {"orientation": "normal"},
            "api": {"api_key": api_key, "port": 80},
            "playlist": {"enabled": False, "cycling": False, "default_display_time": 30, "urls": []}
        }


        try:
            with open(CONFIG_FILE, 'w') as f:
                json.dump(default_config, f, indent=2)
        except:
            pass

        return default_config

def check_auth(handler):
    config = load_config()
    api_config = config.get("api", {})

    query = parse_qs(urlparse(handler.path).query)
    api_key = query.get('api_key', [''])[0]

    if api_key != api_config.get('api_key', ''):
        handler.send_response(401)
        handler.send_header('Content-type', 'application/json')
        handler.end_headers()
        handler.wfile.write(json.dumps({"error": "Invalid API key"}).encode())
        return False
    return True

def execute_kiosk_command(command, args=None, timeout=30):
    """Execute a kiosk command via kiosk-setup.sh"""
    try:
        cmd = ['bash', KIOSK_SCRIPT, command]
        if args:
            if isinstance(args, list):
                cmd.extend([str(arg) for arg in args])
            elif isinstance(args, str):
                cmd.append(args)

        start_time = time.time()
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )

        execution_time = time.time() - start_time


        clean_stdout = result.stdout.strip()
        clean_stderr = result.stderr.strip()


        import re
        ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
        clean_stdout = ansi_escape.sub('', clean_stdout)
        clean_stderr = ansi_escape.sub('', clean_stderr)


        if clean_stdout:
            lines = [line.strip() for line in clean_stdout.split('\n') if line.strip()]

            clean_lines = []
            skip_json = False
            for line in lines:
                if line.startswith('[DEBUG]') or line.startswith('DEBUG:'):
                    continue
                if line in ['SUCCESS', 'FAILED']:
                    continue
                if '"description":' in line or '"id":' in line or '"webSocketDebuggerUrl":' in line:
                    skip_json = True
                    continue
                if skip_json and (line.startswith('"') or line == '}'):
                    if line == '}':
                        skip_json = False
                    continue
                if 'WebSocket' in line or 'Method 1' in line or 'devtools' in line:
                    continue
                clean_lines.append(line)
            clean_stdout = '\n'.join(clean_lines) if clean_lines else clean_stdout

        if clean_stderr:
            lines = [line.strip() for line in clean_stderr.split('\n') if line.strip()]

            clean_lines = []
            for line in lines:
                if line.startswith('[DEBUG]') or line.startswith('DEBUG:'):
                    continue
                if 'WebSocket' in line or 'devtools' in line:
                    continue
                if '"description":' in line or '"id":' in line:
                    continue
                clean_lines.append(line)
            clean_stderr = '\n'.join(clean_lines[-3:]) if clean_lines else ""

        return {
            "success": result.returncode == 0,
            "exit_code": result.returncode,
            "output": clean_stdout,
            "error": clean_stderr,
            "execution_time": round(execution_time, 3),
            "command": " ".join(cmd)
        }

    except subprocess.TimeoutExpired:
        return {"success": False, "error": f"Command timed out after {timeout} seconds", "output": "", "exit_code": -1}
    except Exception as e:
        return {"success": False, "error": str(e), "output": "", "exit_code": -1}

class KioskCommandHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if not check_auth(self):
            return

        if self.path.startswith('/status'):
            result = execute_kiosk_command('status')
            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/get-url'):
            result = execute_kiosk_command('get-url')
            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/get-rotation'):
            result = execute_kiosk_command('get-rotation')
            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/api-info'):
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()

            response = {
                "message": "Kiosk Command API Gateway",
                "description": "REST API that triggers kiosk CLI commands",
                "endpoints": [
                    "GET /status - Run 'kiosk status'",
                    "GET /get-url - Run 'kiosk get-url'",
                    "GET /get-rotation - Run 'kiosk get-rotation'",
                    "GET /get-api-key - Run 'kiosk get-api-key'",
                    "POST /set-url - Run 'kiosk set-url <URL>'",
                    "POST /set-display-orientation - Set display orientation (normal|left|right|inverted)",
                    "POST /start - Run 'sudo kiosk start'",
                    "POST /stop - Run 'sudo kiosk stop'",
                    "POST /restart - Run 'sudo kiosk restart'",
                    "POST /playlist-enable - Enable playlist cycling",
                    "POST /playlist-disable - Disable playlist cycling",
                    "GET /playlist - Show current playlist",
                    "POST /playlist-add - Add URL to playlist",
                    "POST /playlist-remove - Remove URL from playlist",
                    "POST /playlist-replace - Replace entire playlist",
                    "POST /playlist-clear - Clear playlist"
                ],
                "usage": {
                    "set_url": {
                        "method": "POST",
                        "endpoint": "/set-url",
                        "options": [
                            "URL param: ?api_key=KEY&url=http://google.com",
                            "JSON body: {\"url\": \"http://google.com\"}"
                        ]
                    },
                    "set_display_orientation": {
                        "method": "POST",
                        "endpoint": "/set-display-orientation",
                        "options": [
                            "URL param: ?api_key=KEY&orientation=left",
                            "JSON body: {\"orientation\": \"left\"}"
                        ]
                    }
                }
            }
            self.wfile.write(json.dumps(response, indent=2).encode())

        elif self.path.startswith('/playlist'):

            result = execute_kiosk_command('playlist')
            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if not check_auth(self):
            return

        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)

        try:
            data = json.loads(post_data.decode()) if content_length > 0 else {}
        except Exception as e:

            data = {}

        if self.path.startswith('/set-url'):

            parsed_url = urlparse(self.path)
            query_params = parse_qs(parsed_url.query)
            url_param = query_params.get('url', [''])[0]

            if url_param:
                result = execute_kiosk_command('set-url', url_param.strip())
            elif data.get('url'):
                result = execute_kiosk_command('set-url', data['url'])
            elif data.get('urls'):

                self.send_response(400)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "error": "Multiple URLs not allowed in set-url endpoint",
                    "message": "Use playlist endpoints for multiple URLs",
                    "endpoints": {
                        "replace_playlist": "/playlist-replace",
                        "add_to_playlist": "/playlist-add",
                        "enable_playlist": "/playlist-enable"
                    }
                }).encode())
                return
            else:
                self.send_response(400)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Single URL required (use ?url=... or JSON body with 'url')"}).encode())
                return

            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/set-display-orientation'):

            query = parse_qs(urlparse(self.path).query)
            orientation_param = query.get('orientation', [''])[0]

            if orientation_param:

                orientation = orientation_param.strip()
            else:

                orientation = data.get('orientation', '').strip()

            if not orientation:
                self.send_response(400)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Display orientation required (use ?orientation=... or JSON body with 'orientation')"}).encode())
                return

            result = execute_kiosk_command('set-display-orientation', orientation)
            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/start'):

            result = subprocess.run(['sudo', 'bash', KIOSK_SCRIPT, 'start'], capture_output=True, text=True)
            response = {
                "success": result.returncode == 0,
                "exit_code": result.returncode,
                "output": result.stdout.strip(),
                "error": result.stderr.strip(),
                "command": f"sudo bash {KIOSK_SCRIPT} start"
            }
            self.send_response(200 if response["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response, indent=2).encode())

        elif self.path.startswith('/stop'):
            result = subprocess.run(['sudo', 'bash', KIOSK_SCRIPT, 'stop'], capture_output=True, text=True)
            response = {
                "success": result.returncode == 0,
                "exit_code": result.returncode,
                "output": result.stdout.strip(),
                "error": result.stderr.strip(),
                "command": f"sudo bash {KIOSK_SCRIPT} stop"
            }
            self.send_response(200 if response["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response, indent=2).encode())

        elif self.path.startswith('/restart'):
            result = subprocess.run(['sudo', 'bash', KIOSK_SCRIPT, 'restart'], capture_output=True, text=True)
            response = {
                "success": result.returncode == 0,
                "exit_code": result.returncode,
                "output": result.stdout.strip(),
                "error": result.stderr.strip(),
                "command": f"sudo bash {KIOSK_SCRIPT} restart"
            }
            self.send_response(200 if response["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response, indent=2).encode())

        elif self.path.startswith('/playlist-enable'):
            result = execute_kiosk_command('playlist-enable')
            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/playlist-disable'):
            result = execute_kiosk_command('playlist-disable')
            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/playlist-add'):


            parsed_url = urlparse(self.path)
            query_params = parse_qs(parsed_url.query)
            url_param = query_params.get('url', [''])[0]

            if url_param:

                duration_param = query_params.get('duration', ['30'])[0]
                title_param = query_params.get('title', [''])[0]
                args = [url_param, duration_param]
                if title_param:
                    args.append(title_param)
                result = execute_kiosk_command('playlist-add', args)
            elif data.get('url'):

                url = data['url']
                duration = data.get('duration', 30)
                title = data.get('title', '')
                args = [url, str(duration)]
                if title:
                    args.append(title)
                result = execute_kiosk_command('playlist-add', args)
            else:
                self.send_response(400)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": "URL required (use ?url=... or JSON body)"}).encode())
                return

            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/playlist-remove'):

            parsed_url = urlparse(self.path)
            query_params = parse_qs(parsed_url.query)
            index_param = query_params.get('index', [''])[0]

            if index_param:

                result = execute_kiosk_command('playlist-remove', index_param)
            elif data.get('index') is not None:

                result = execute_kiosk_command('playlist-remove', str(data['index']))
            else:
                self.send_response(400)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Index required (use ?index=... or JSON body)"}).encode())
                return

            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/playlist-replace'):

            parsed_url = urlparse(self.path)
            query_params = parse_qs(parsed_url.query)
            url_param = query_params.get('url', [''])[0]


            if url_param:

                duration_param = query_params.get('duration', ['30'])[0]
                title_param = query_params.get('title', [''])[0]
                args = [url_param, duration_param]
                if title_param:
                    args.append(title_param)
                result = execute_kiosk_command('playlist-replace', args)
            elif data.get('url'):

                url = data['url']
                duration = data.get('duration', 30)
                title = data.get('title', '')
                args = [url, str(duration)]
                if title:
                    args.append(title)
                result = execute_kiosk_command('playlist-replace', args)
            elif data.get('urls'):

                urls = data['urls']


                first_url = True
                operations = []
                all_success = True

                for url_item in urls:
                    if isinstance(url_item, dict):
                        url = url_item.get('url', '')
                        duration = url_item.get('duration', 30)
                        title = url_item.get('title', '')
                        args = [url, str(duration)]
                        if title:
                            args.append(title)
                    elif isinstance(url_item, str):
                        args = [url_item, '30']

                    if first_url:
                        result = execute_kiosk_command('playlist-replace', args)
                        operations.append(f"Replaced playlist with: {url}")
                        first_url = False
                    else:
                        result = execute_kiosk_command('playlist-add', args)
                        operations.append(f"Added to playlist: {url}")

                    if not result["success"]:
                        all_success = False
                        break


                if len(urls) > 0 and all_success:

                    import time
                    time.sleep(0.5)

                    enable_result = execute_kiosk_command('playlist-enable')
                    if enable_result["success"]:
                        operations.append("Playlist enabled and cycling started")
                    else:
                        all_success = False
                        operations.append("Failed to enable playlist")


                result = {
                    "success": all_success,
                    "exit_code": 0 if all_success else 1,
                    "output": "; ".join(operations),
                    "error": "" if all_success else "Some operations failed",
                    "execution_time": 0.1,
                    "command": f"playlist-replace with {len(urls)} URLs"
                }
            else:
                self.send_response(400)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": "URL required (use ?url=... or JSON body)"}).encode())
                return

            self.send_response(200 if result["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())

        elif self.path.startswith('/playlist-clear'):

            result = subprocess.run(['sudo', 'bash', KIOSK_SCRIPT, 'playlist-clear'], capture_output=True, text=True)
            response = {
                "success": result.returncode == 0,
                "exit_code": result.returncode,
                "output": result.stdout.strip(),
                "error": result.stderr.strip(),
                "command": f"sudo bash {KIOSK_SCRIPT} playlist-clear"
            }
            self.send_response(200 if response["success"] else 500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response, indent=2).encode())

        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    print("Starting Kiosk Command API Gateway...")
    print(f"Kiosk Script: {KIOSK_SCRIPT}")

    try:
        server = HTTPServer(('0.0.0.0', 80), KioskCommandHandler)
        print("Kiosk Command API Gateway running on port 80")
        server.serve_forever()
    except PermissionError:
        print("Permission denied for port 80, trying port 8080...")
        server = HTTPServer(('0.0.0.0', 8080), KioskCommandHandler)
        print("Kiosk Command API Gateway running on port 8080")
        server.serve_forever()
EOF
    
    chmod +x "$INSTALL_DIR/simple_api.py"
}

create_systemd_services() {
    log_info "Creating systemd services for API Gateway..."
    

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Kiosk Display System
After=graphical.target
Wants=graphical.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/start_kiosk.sh
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=10
User=root
Group=root
StandardOutput=journal
StandardError=journal
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=graphical.target
EOF
    

    cat > "$API_SERVICE_FILE" << EOF
[Unit]
Description=API-to-Script Gateway
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/simple_api.py
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5
User=root
Group=root
Environment=SCRIPTS_DIR=/opt/kiosk/scripts

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable kiosk.service
    systemctl enable kiosk-api.service
    
    log_info "Systemd services created and enabled"
}

enable_autologin() {
    log_info "Enabling autologin for user '$KIOSK_USER'..."
    
    cat > /etc/systemd/system/getty@tty1.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
    
    systemctl daemon-reexec
    log_info "Autologin enabled"
}

set_permissions() {
    log_info "Setting up permissions..."
    
    chown -R root:root "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
    chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true
    chmod 644 "$CONFIG_FILE" 2>/dev/null || true
    
    log_info "Permissions configured"
}

mark_setup_complete() {
    echo "Setup completed at: $(date)" > "$SETUP_MARKER"
    log_info "Setup marked as complete"
}

print_setup_info() {
    local api_key
    api_key=$(get_config_value "api.api_key" "default-key")
    local arch_info="$ARCH"
    [[ "$IS_RPI" == true ]] && arch_info="$arch_info (Raspberry Pi)"

    echo "" >&2
    echo "============================================" >&2
    echo "    KIOSK API GATEWAY INSTALLATION COMPLETE!" >&2
    echo "============================================" >&2
    echo "Architecture: $arch_info" >&2
    echo "User '$KIOSK_USER' created" >&2
    echo "Browser: $CHROMIUM_PATH" >&2
    echo "System packages installed" >&2
    echo "Systemd services configured (kiosk + API gateway)" >&2
    echo "Autologin enabled" >&2
    echo "Screen blanking disabled" >&2
    echo "Script: /opt/kiosk/kiosk-setup.sh" >&2
    echo "Command: kiosk (CLI access)" >&2
    echo "Examples: cat /opt/kiosk/USAGE_EXAMPLES.md" >&2
    echo "" >&2
    echo "API GATEWAY CONFIGURATION:" >&2
    echo "   API Key: $api_key" >&2
    echo "   Config: $CONFIG_FILE" >&2
    echo "   Examples: $INSTALL_DIR/USAGE_EXAMPLES.md" >&2
    echo "" >&2
    local ip_addr=$(hostname -I | awk '{print $1}' 2>/dev/null || echo '<this-ip>')
    echo "API ENDPOINTS (available after reboot):" >&2
    echo "   Status:    http://$ip_addr/status?api_key=$api_key" >&2
    echo "   Set URL:   http://$ip_addr/set-url?api_key=$api_key&url=<URL>" >&2
    echo "   Playlist:  http://$ip_addr/playlist?api_key=$api_key" >&2
    echo "   Orientation:  http://$ip_addr/set-display-orientation?api_key=$api_key&orientation=<orientation>" >&2
    echo "   API Info:  http://$ip_addr/api-info?api_key=$api_key" >&2
    echo "" >&2
    echo "QUICK START:" >&2
    echo "   1. sudo reboot" >&2
    echo "   2. System auto-starts kiosk + API gateway" >&2
    echo "   3. Set URL: curl -X POST \"http://$ip_addr/set-url?api_key=$api_key&url=http://your-site.com\"" >&2
    echo "   4. CLI: kiosk status | kiosk set-url <URL> | kiosk playlist" >&2
    echo "   5. Full examples: cat $INSTALL_DIR/USAGE_EXAMPLES.md" >&2
    echo "========================================" >&2
}



get_url() {
    local result
    result=$(get_config_value "kiosk.url" "http://example.com")
    echo "$result"
}

set_url() {
    local url="$1"

    if [[ -z "$url" ]]; then
        log_error "URL is required"
        echo "Usage: kiosk set-url <URL>"
        echo "Example: kiosk set-url http://google.com"
        exit 1
    fi
    

    if ! validate_url "$url"; then
        log_error "Invalid or unsafe URL provided"
        exit 1
    fi
    

    # Auto-refresh functionality removed - memory management handles browser health

    set_config_value "kiosk.url" "$url"
    set_config_value "playlist.enabled" "false"


    log_info "URL set to: $url"
    

    log_info "Navigating browser to new URL..."
    if navigate_browser_to_url "$url"; then
        log_info "Successfully navigated to: $url"
    else
        log_warn "DevTools navigation failed, restarting kiosk service as fallback..."
        if ! retry_command 3 5 "systemctl restart kiosk.service"; then
            log_error "Failed to restart kiosk service after multiple attempts"
            log_warn "Attempting to restore previous configuration..."
            restore_config "kiosk_url.txt" || log_error "Failed to restore configuration"
            exit 1
        fi
        log_info "Kiosk service restarted successfully"
    fi
}

get_rotation() {
    get_config_value "display.orientation" "normal"
}

set_display_orientation() {
    local orientation="$1"

    if [[ -z "$orientation" ]]; then
        log_error "Display orientation is required"
        echo "Usage: kiosk set-display-orientation <normal|left|right|inverted>"
        exit 1
    fi
    

    if ! validate_rotation "$orientation"; then
        log_error "Invalid display orientation value provided"
        exit 1
    fi


    orientation=$(echo "$orientation" | tr '[:upper:]' '[:lower:]')


    backup_config


    set_config_value "display.orientation" "$orientation"

    log_info "Display orientation set to: $orientation"


    log_info "Restarting kiosk service to apply orientation..."
    if systemctl restart kiosk.service 2>/dev/null; then
        log_info "Kiosk service restarted successfully - orientation applied"
        echo "SUCCESS"
    else
        log_warn "Could not restart kiosk service automatically"
        log_info "Display orientation will be applied on next manual restart"
        echo "SUCCESS"
    fi
}

get_api_key() {
    get_config_value "api.api_key" "default-key"
}

regenerate_api_key() {
    check_root "regenerate-api-key"
    
    local new_key
    new_key=$(generate_api_key)
    

    set_config_value "api.api_key" "$new_key"
    set_config_value "api.require_auth" "true"
    
    log_info "New API key generated: $new_key"
    
    log_info "Restarting API service..."
    systemctl restart kiosk-api.service
}

show_status() {
    local detailed="${1:-false}"
    
    if [[ "$detailed" == "true" ]]; then
        get_system_health_report
        return $?
    fi
    
    echo "========================================"
    echo "         KIOSK STATUS"
    echo "========================================"
    

    local arch_info="$ARCH"
    [[ "$IS_RPI" == true ]] && arch_info="$arch_info (Raspberry Pi)"
    echo "Architecture:     $arch_info"
    echo "Timestamp:        $(date)"
    echo
    

    local service_issues=0
    
    if systemctl is-active --quiet kiosk.service; then
        echo -e "Kiosk Service:    ${GREEN}RUNNING${NC}"
    else
        echo -e "Kiosk Service:    ${RED}STOPPED${NC}"
        ((service_issues++))
    fi
    
    if systemctl is-active --quiet kiosk-api.service; then
        echo -e "API Service:      ${GREEN}RUNNING${NC}"
    else
        echo -e "API Service:      ${RED}STOPPED${NC}"
        ((service_issues++))
    fi
    

    if pgrep Xorg > /dev/null; then
        echo -e "X Server:         ${GREEN}RUNNING${NC}"
    else
        echo -e "X Server:         ${RED}STOPPED${NC}"
        ((service_issues++))
    fi
    
    if pgrep -f chromium > /dev/null; then
        local browser_memory
        browser_memory=$(get_browser_memory_kb)
        local mem_status="OK"
        local mem_color="$GREEN"
        
        if [[ $browser_memory -gt $BROWSER_MEMORY_LIMIT ]]; then
            mem_status="HIGH"
            mem_color="$YELLOW"
        fi
        
        echo -e "Browser:          ${GREEN}RUNNING${NC} (Memory: ${mem_color}${browser_memory}KB - ${mem_status}${NC})"
    else
        echo -e "Browser:          ${RED}STOPPED${NC}"
        ((service_issues++))
    fi
    
    echo "========================================"
    

    local url
    url=$(get_url 2>/dev/null)
    if validate_url "$url" >/dev/null 2>&1; then
        echo -e "Current URL:      ${GREEN}$url${NC}"
    else
        echo -e "Current URL:      ${RED}$url (INVALID)${NC}"
    fi
    
    local rotation
    rotation=$(get_rotation 2>/dev/null)
    if validate_rotation "$rotation" >/dev/null 2>&1; then
        echo -e "Current Rotation: ${GREEN}$rotation${NC}"
    else
        echo -e "Current Rotation: ${RED}$rotation (INVALID)${NC}"
    fi
    
    echo "API Key:          $(get_api_key | cut -c1-8)..."
    

    local ip_addr
    ip_addr=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    echo "IP Address:       ${ip_addr:-"Unknown"}"
    
    echo "========================================"
    

    if [[ $service_issues -eq 0 ]]; then
        echo -e "Overall Status:   ${GREEN}HEALTHY${NC}"
    elif [[ $service_issues -le 2 ]]; then
        echo -e "Overall Status:   ${YELLOW}DEGRADED${NC} ($service_issues issues)"
    else
        echo -e "Overall Status:   ${RED}CRITICAL${NC} ($service_issues issues)"
    fi
    
    echo "========================================"
    echo
    echo "Commands: 'kiosk health' for detailed report"
    echo "          'kiosk logs' to view service logs"
}

start_services() {
    check_root "start"
    log_info "Starting kiosk services..."
    systemctl start kiosk.service
    systemctl start kiosk-api.service
    log_info "Services started"
}

stop_services() {
    check_root "stop"
    log_info "Stopping kiosk services..."
    systemctl stop kiosk.service
    systemctl stop kiosk-api.service
    log_info "Services stopped"
}

restart_services() {
    check_root "restart"
    log_info "Restarting kiosk services..."
    systemctl restart kiosk.service
    systemctl restart kiosk-api.service
    log_info "Services restarted"
}

show_logs() {
    local service="${1:-kiosk}"
    
    case "$service" in
        "kiosk"|"browser")
            journalctl -u kiosk.service -f
            ;;
        "api")
            journalctl -u kiosk-api.service -f
            ;;
        *)
            log_error "Invalid service: $service"
            echo "Available services: kiosk, api"
            exit 1
            ;;
    esac
}

test_api() {
    local api_key
    api_key=$(get_api_key)
    local base_url="http://localhost"
    
    log_info "Testing API endpoints..."
    
    echo -n "Testing /status: "
    if curl -s "${base_url}/status?api_key=${api_key}" | grep -q "online"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    echo -n "Testing /api-info: "
    if curl -s "${base_url}/api-info" | grep -q "Kiosk API"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi
    
    log_info "API test completed"
}

install_to_system() {
    check_root "install"
    
    local script_name="kiosk"
    local install_path="/usr/local/bin/$script_name"
    
    cp "$0" "$install_path"
    chmod +x "$install_path"
    
    log_info "Script installed to $install_path"
    log_info "You can now run: $script_name <command>"
}

uninstall_system() {
    check_root "uninstall"
    
    log_warn "This will completely remove the kiosk system!"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstall cancelled"
        exit 0
    fi
    
    log_info "Stopping and disabling services..."
    systemctl stop kiosk.service kiosk-api.service 2>/dev/null || true
    systemctl disable kiosk.service kiosk-api.service 2>/dev/null || true
    
    log_info "Removing files..."
    rm -rf "$INSTALL_DIR/"
    rm -f "$SERVICE_FILE" "$API_SERVICE_FILE"
    rm -f /etc/systemd/system/getty@tty1.service.d/override.conf
    rm -f /etc/X11/xorg.conf.d/10-screen.conf
    
    log_info "Removing user..."
    userdel -r "$KIOSK_USER" 2>/dev/null || true
    
    systemctl daemon-reload
    
    log_info "Kiosk system uninstalled"
}

show_help() {
    echo "Universal Kiosk Management System"
    echo
    echo "SETUP (run once as root):"
    echo "  sudo $0 setup                 - Complete system setup"
    echo
    echo "MANAGEMENT:"
    echo "  kiosk status                     - Show system status"
    echo "  kiosk get-url                    - Get current URL"
    echo "  kiosk set-url <URL>              - Set URL and restart browser"
    echo "  kiosk get-rotation               - Get current display orientation"
    echo "  kiosk set-display-orientation <orientation> - Set display orientation (normal|left|right|inverted)"
    echo "  kiosk get-api-key                - Show current API key"
    echo "  kiosk regenerate-api-key         - Generate new API key (requires root)"
    echo
    echo "SERVICE MANAGEMENT (requires root):"
    echo "  sudo kiosk start                 - Start kiosk services"
    echo "  sudo kiosk stop                  - Stop kiosk services"
    echo "  sudo kiosk restart               - Restart kiosk services"
    echo "  kiosk logs [service]             - Show logs (service: kiosk, api)"
    echo
    echo "UTILITIES:"
    echo "  kiosk test-api                   - Test API endpoints"
    echo "  sudo kiosk install               - Install script to system PATH"
    echo "  sudo kiosk uninstall             - Completely remove kiosk system"
    echo "  kiosk help                       - Show this help"
    echo
    echo "EXAMPLES:"
    echo "  kiosk set-url http://google.com       # Memory management handles browser health"
    echo "  kiosk set-display-orientation left"
    echo "  kiosk logs kiosk"
    echo
    echo "API USAGE:"
    echo "
    echo "  curl \"http://<ip>/status?api_key=<key>\""
    echo "
    echo "  curl \"http://<ip>/get-url?api_key=<key>\""
    echo "
    echo "  curl -X POST \"http://<ip>/set-url?api_key=<key>\" -H \"Content-Type: application/json\" -d '{\"url\":\"http://google.com\"}'"
    echo "
    echo "  curl \"http://<ip>/get-rotation?api_key=<key>\""
    echo "
    echo "  curl -X POST \"http://<ip>/set-rotation?api_key=<key>\" -H \"Content-Type: application/json\" -d '{\"rotation\":\"left\"}'"
    echo "
    echo "  curl -X POST \"http://<ip>/start?api_key=<key>\""
    echo "  curl -X POST \"http://<ip>/stop?api_key=<key>\""
    echo "  curl -X POST \"http://<ip>/restart?api_key=<key>\""
    echo "
    echo "  curl \"http://<ip>/logs?api_key=<key>\""
    echo "
    echo "  curl \"http://<ip>/api-info?api_key=<key>\""
}



enable_autologin() {
    log_info "Enabling autologin for user '$KIOSK_USER'..."
    mkdir -p /etc/systemd/system/getty@tty1.service.d/
    cat > /etc/systemd/system/getty@tty1.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
    systemctl disable lightdm 2>/dev/null || true
    systemctl disable gdm 2>/dev/null || true
    systemctl disable sddm 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable getty@tty1.service
    log_info "Autologin enabled for user '$KIOSK_USER'"
}

run_setup() {
    check_root "setup"
    
    log_title "KIOSK SYSTEM SETUP"
    log_info "Architecture: $ARCH"
    [[ "$IS_ARM" == true ]] && log_info "ARM system detected"
    [[ "$IS_RPI" == true ]] && log_info "Raspberry Pi detected"
    
    if [[ -f "$SETUP_MARKER" ]]; then
        log_warn "Setup already completed. Use 'uninstall' first to re-run setup."
        exit 0
    fi
    
    log_title "Creating User"
    create_kiosk_user
    
    log_title "Installing Packages"
    install_system_packages
    install_python_packages
    
    log_title "Detecting Browser"
    detect_chromium_path
    
    log_title "Setting up Configuration"
    create_directories
    create_default_configs
    create_usage_examples
    
    log_title "Configuring System"
    disable_screen_blanking
    create_kiosk_script
    create_simple_api
    create_systemd_services
    enable_autologin
    
    log_title "Setting Permissions"
    set_permissions
    
    mark_setup_complete
    print_setup_info

    log_info "Setup complete! Please reboot the system."
}



main() {

    if [[ -z "${1:-}" && "$0" =~ /dev/fd/ ]]; then
        log_info "One-line installer detected"
        if [[ $EUID -eq 0 ]]; then
            log_info "Running as root, proceeding with setup..."
            

            log_info "Saving kiosk-setup.sh script for future use..."
            mkdir -p /opt/kiosk
            curl -s https://raw.githubusercontent.com/zitlem/Kiosk-URL/master/kiosk-setup.sh -o /opt/kiosk/kiosk-setup.sh 2>/dev/null || {
                log_warn "Could not download script for saving, copying current script..."

                cp "$0" /opt/kiosk/kiosk-setup.sh 2>/dev/null || true
            }
            
            chmod +x /opt/kiosk/kiosk-setup.sh 2>/dev/null || true
            

            ln -sf /opt/kiosk/kiosk-setup.sh /usr/local/bin/kiosk 2>/dev/null || true
            
            log_info "Running setup..."
            run_setup

            log_info "System will reboot in 10 seconds..."
            log_info "Press Ctrl+C to cancel reboot and reboot manually later"
            for i in {10..1}; do
                echo -n "$i... "
                sleep 1
            done
            echo
            log_info "Rebooting now..."
            reboot
        else
            log_error "One-line install must be run as root!"
            echo
            echo "🚀 ONE-LINE KIOSK INSTALLER"
            echo
            echo "Use this command:"
            echo "  sudo bash <(curl -s https://raw.githubusercontent.com/zitlem/Kiosk-URL/master/kiosk-setup.sh)"
            echo
            echo "This will:"
            echo "  ✅ Install and configure complete kiosk system"
            echo "  ✅ Set up automatic browser cycling with URL playlist"
            echo "  ✅ Enable remote API management"  
            echo "  ✅ Optimize for your hardware (x86/ARM/Raspberry Pi)"
            echo "  ✅ Create systemd services"
            echo "  ✅ Save management script for future use"
            echo "  ✅ Auto-reboot when complete"
            echo
            exit 1
        fi
        return
    fi
    

    set -eE
    trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR
    
    case "${1:-}" in
        "setup")
            run_setup
            ;;
        "status")
            show_status
            ;;
        "health")
            get_system_health_report
            ;;
        "get-url")
            get_url
            ;;
        "set-url")
            set_url "$2"
            ;;
        "get-rotation")
            get_rotation
            ;;
        "set-display-orientation")
            if [[ -z "$2" ]]; then
                log_error "Display orientation is required"
                echo "Usage: kiosk set-display-orientation <normal|left|right|inverted>"
                exit 1
            fi
            set_display_orientation "$2"
            ;;
        "get-api-key")
            get_api_key
            ;;
        "regenerate-api-key")
            regenerate_api_key
            ;;
        "start")
            start_services
            ;;
        "stop")
            stop_services
            ;;
        "restart")
            restart_services
            ;;
        "logs")
            show_logs "$2"
            ;;
        "test-api")
            test_api
            ;;
        "install")
            install_to_system
            ;;
        "uninstall")
            uninstall_system
            ;;

        "backup-config")
            check_root "backup-config"
            backup_config
            ;;
        "restore-config")
            check_root "restore-config"
            if [[ -z "$2" ]]; then
                log_error "Config name required: kiosk_url.txt, api_config.json, or rotation_config.txt"
                exit 1
            fi
            restore_config "$2"
            ;;
        "validate-config")
            log_info "Validating configurations..."
            local errors=0
            
            if ! validate_config_file "$CONFIG_FILE" "url"; then
                ((errors++))
            fi
            

            
            if ! validate_config_file "$CONFIG_FILE" "playlist"; then
                ((errors++))
            fi
            
            if [[ $errors -eq 0 ]]; then
                log_info "All configurations are valid"
            else
                log_error "Found $errors configuration errors"
                exit 1
            fi
            ;;

        "playlist")
            show_playlist
            ;;
        "playlist-add")
            if [[ -z "$2" ]]; then
                log_error "URL is required"
                echo "Usage: kiosk playlist-add <URL> [display_time] [title]"
                exit 1
            fi
            add_playlist_url "$2" "$3" "$4" "add"
            ;;
        "playlist-replace")
            if [[ -z "$2" ]]; then
                log_error "URL is required"
                echo "Usage: kiosk playlist-replace <URL> [display_time] [title]"
                exit 1
            fi
            add_playlist_url "$2" "$3" "$4" "replace"
            ;;
        "playlist-set")

            if [[ -z "$2" ]]; then
                log_error "URL is required"
                echo "Usage: kiosk playlist-set <URL> [display_time] [title]"
                exit 1
            fi
            add_playlist_url "$2" "$3" "$4" "replace"
            ;;
        "playlist-remove")
            if [[ -z "$2" ]]; then
                log_error "URL index is required"
                echo "Usage: kiosk playlist-remove <index>"
                exit 1
            fi
            remove_playlist_url "$2"
            ;;
        "playlist-enable")
            enable_playlist
            log_info "Navigating to first playlist URL..."

            navigate_browser_to_url "$(get_current_playlist_url)" || {
                log_warn "DevTools navigation failed, restarting service as fallback"
                systemctl restart kiosk.service 2>/dev/null || log_warn "Could not restart service automatically"
            }
            ;;
        "playlist-disable")
            disable_playlist
            log_info "Navigating to single URL..."

            navigate_browser_to_url "$(get_url)" || {
                log_warn "DevTools navigation failed, restarting service as fallback"
                systemctl restart kiosk.service 2>/dev/null || log_warn "Could not restart service automatically"
            }
            ;;
        "playlist-clear")
            check_root "playlist-clear"
            backup_config
            create_default_playlist
            log_info "Playlist cleared to default state"
            ;;

        "debug")
            save_debug_state
            log_info "Debug information collected"
            ;;
        "clean-logs")
            check_root "clean-logs"
            log_info "Cleaning old log files..."
            journalctl --vacuum-time=7d 2>/dev/null || true
            find /var/log -name "*kiosk*" -type f -mtime +7 -delete 2>/dev/null || true
            find /tmp -name "kiosk-debug-*" -type d -mtime +1 -exec rm -rf {} + 2>/dev/null || true
            log_info "Log cleanup completed"
            ;;
        "monitor")
            log_info "Starting system monitoring (Ctrl+C to stop)..."
            while true; do
                clear
                show_status
                echo
                echo "Refreshing every 10 seconds... (Ctrl+C to exit)"
                sleep 10
            done
            ;;

        "version")
            echo "Universal Kiosk Management System"
            echo "Architecture: $ARCH"
            [[ "$IS_ARM" == true ]] && echo "ARM optimizations: Enabled"
            [[ "$IS_RPI" == true ]] && echo "Raspberry Pi optimizations: Enabled"
            echo "Browser path: ${CHROMIUM_PATH:-"Not detected"}"
            

            if command -v snap >/dev/null 2>&1 && snap list chromium >/dev/null 2>&1; then
                echo "Browser installation: Snap"
                echo "Update command: sudo snap refresh chromium"
            elif dpkg -l 2>/dev/null | grep -q chromium; then
                echo "Browser installation: APT"  
                echo "Update command: sudo apt update && sudo apt upgrade chromium-browser -y"
            else
                echo "Browser installation: Unknown"
            fi
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        "")
            echo "Universal Kiosk Management System"
            echo "Run 'kiosk help' for usage information"
            echo "Run 'sudo $0 setup' for initial setup"
            echo "Run 'kiosk status' for current system status"
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run 'kiosk help' for available commands"
            exit 1
            ;;
    esac
}


main "$@"
