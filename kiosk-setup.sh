#!/bin/bash

# Universal Kiosk Management System
# Complete setup and management solution for kiosk systems
# Supports both x86 and ARM architectures (including Raspberry Pi)
#
# Usage:
#   Initial setup:    sudo $0 setup
#   Management:       ./kiosk-setup.sh <command>  
#   Help:            ./kiosk-setup.sh help

set -e  # Exit on error

# ==========================================
# CONFIGURATION AND CONSTANTS
# ==========================================

KIOSK_USER="kiosk"
INSTALL_DIR="/opt/kiosk"
CONFIG_FILE="$INSTALL_DIR/kiosk.json"
SERVICE_FILE="/etc/systemd/system/kiosk.service"
API_SERVICE_FILE="/etc/systemd/system/kiosk-api.service"
SETUP_MARKER="$INSTALL_DIR/.setup_complete"
DEBUG_PORT=9222
CHROMIUM_PATH=""

# Architecture detection
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

# Package lists - architecture-specific
SYSTEM_PACKAGES=(
    "xserver-xorg"
    "x11-xserver-utils"
    "xinit"
    "openbox"
    "unclutter"
    "python3"
    "python3-pip"
    "python3-xdg"
    "curl"
    "jq"
    "gnupg"
    "ca-certificates"
    "coreutils"
    "openssl"
)

ARM_PACKAGES=(
    "chromium-browser"
    "rpi-chromium-mods"
    "libraspberrypi-bin"
    "libraspberrypi0"
)

X86_PACKAGES=(
    "chromium-browser"
)

PYTHON_PACKAGES=(
    "flask"
    "requests"
    "websocket-client"
)

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
BROWSER_RESTART_THRESHOLD=5
BROWSER_MEMORY_LIMIT=2048000  # 2GB in KB

# URL playlist configuration
DEFAULT_DISPLAY_TIME=30       # Default seconds per URL
PLAYLIST_MODE=false          # Single URL mode by default
CURRENT_URL_INDEX=0         # Current position in playlist

# ==========================================
# UTILITY FUNCTIONS
# ==========================================

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

# Enhanced error handling functions
handle_error() {
    local exit_code=$1
    local line_number=$2
    local command="$3"
    
    log_critical "Command failed with exit code $exit_code on line $line_number: $command"
    
    # Save system state for debugging
    save_debug_state
    
    # Attempt recovery based on context
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
    log_info "Attempting browser recovery..."
    
    # Kill existing browser processes
    pkill -f chromium 2>/dev/null || true
    sleep 2
    pkill -9 -f chromium 2>/dev/null || true
    
    # Clear browser cache and temp files
    rm -rf /tmp/chromium-kiosk 2>/dev/null || true
    
    # Check if X server is running
    if ! pgrep Xorg >/dev/null; then
        log_warn "X server not running, restarting display system..."
        recover_display
    fi
    
    # Restart kiosk service
    if systemctl is-enabled kiosk.service >/dev/null 2>&1; then
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
    
    # Kill existing X processes
    pkill -f "X :0" 2>/dev/null || true
    sleep 2
    
    # Restart X server if we're in the kiosk service context
    if [[ "${0##*/}" == "start_kiosk.sh" ]] || systemctl is-active kiosk.service >/dev/null; then
        log_info "Restarting X server..."
        X :0 -nolisten tcp -noreset +extension GLX vt1 &
        sleep 3
    fi
}

recover_packages() {
    log_info "Attempting package recovery..."
    
    # Fix broken packages
    apt-get install -f -y 2>/dev/null || true
    
    # Update package lists
    apt-get update 2>/dev/null || log_warn "Failed to update package lists"
}

# Retry mechanism for critical operations
retry_command() {
    local max_attempts="${1:-$RETRY_COUNT}"
    local delay="${2:-$RETRY_DELAY}"
    local command="${@:3}"
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        log_debug "Attempt $attempt/$max_attempts: $command"
        
        if eval "$command"; then
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

# Input validation functions
validate_url() {
    local url="$1"
    
    if [[ -z "$url" ]]; then
        log_error "URL cannot be empty"
        return 1
    fi
    
    # Basic URL format validation
    if [[ ! "$url" =~ ^https?://[[:alnum:].-]+(:[0-9]+)?(/.*)?$ ]]; then
        log_error "Invalid URL format: $url"
        return 1
    fi
    
    # Check for malicious patterns
    if [[ "$url" =~ (javascript:|data:|file:|ftp:) ]]; then
        log_error "Potentially unsafe URL scheme: $url"
        return 1
    fi
    
    # URL length check (prevent extremely long URLs)
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
    
    # Convert to lowercase for comparison
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
    
    # Check key length (should be reasonable length)
    if [[ ${#key} -lt 16 ]]; then
        log_error "API key too short (minimum 16 characters)"
        return 1
    fi
    
    if [[ ${#key} -gt 128 ]]; then
        log_error "API key too long (maximum 128 characters)"
        return 1
    fi
    
    # Check for valid characters (alphanumeric + some safe symbols)
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
    
    # Check if it's a positive integer
    if [[ ! "$time" =~ ^[0-9]+$ ]]; then
        log_error "Display time must be a positive integer (seconds)"
        return 1
    fi
    
    # Check reasonable limits (5 seconds to 24 hours)
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
    
    # Validate JSON structure
    if ! python3 -m json.tool "$config_file" >/dev/null 2>&1; then
        log_error "Invalid JSON in playlist config: $config_file"
        return 1
    fi
    
    # Check if required fields exist
    local required_fields=("enabled" "urls")
    for field in "${required_fields[@]}"; do
        if ! grep -q "\"$field\"" "$config_file"; then
            log_error "Missing required field in playlist config: $field"
            return 1
        fi
    done
    
    # Validate each URL in the playlist
    local urls
    urls=$(python3 -c "
import json
with open('$config_file', 'r') as f:
    data = json.load(f)
    for item in data.get('urls', []):
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

# Configuration validation and backup
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

# ==========================================
# UNIFIED CONFIGURATION FUNCTIONS  
# ==========================================

create_default_config() {
    log_info "Creating default unified configuration..."
    
    mkdir -p "$(dirname "$CONFIG_FILE")"
    
    local default_config='{
  "kiosk": {
    "url": "http://example.com",
    "rotation": "normal"
  },
  "api": {
    "api_key": "'"$(generate_api_key)"'",
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
    
    # Check if file is empty or corrupted
    if [[ ! -s "$CONFIG_FILE" ]]; then
        create_default_config
    fi
    
    # Try to output the config first, validate only if that fails
    if cat "$CONFIG_FILE" 2>/dev/null | python3 -c "import json, sys; json.load(sys.stdin)" >/dev/null 2>&1; then
        cat "$CONFIG_FILE"
    else
        log_warn "Invalid config detected, attempting to repair"
        
        # Try to salvage existing settings before recreating
        local backup_content=""
        if [[ -f "$CONFIG_FILE" ]] && [[ -s "$CONFIG_FILE" ]]; then
            backup_content=$(cat "$CONFIG_FILE" 2>/dev/null || echo "")
        fi
        
        # Create default config structure
        create_default_config
        
        # If we had backup content, try to merge valid JSON parts
        if [[ -n "$backup_content" ]]; then
            log_debug "Attempting to merge existing settings"
            
            # Use Python to safely merge any valid JSON from backup
            export KIOSK_CONFIG_FILE="${CONFIG_FILE:-/opt/kiosk/kiosk.json}"
            export KIOSK_BACKUP_CONTENT="$backup_content"
            python3 -c "
import json
import sys
import os

try:
    config_file = os.environ['KIOSK_CONFIG_FILE']
    backup_content = os.environ['KIOSK_BACKUP_CONTENT']
    
    # Load the new default config
    with open(config_file, 'r') as f:
        default_config = json.load(f)
    
    # Try to parse backup content
    
    try:
        backup_config = json.loads(backup_content)
        
        # Merge non-conflicting settings from backup
        for key, value in backup_config.items():
            if key not in ['kiosk', 'playlist']:  # Preserve other settings
                default_config[key] = value
            elif isinstance(value, dict) and key in default_config:
                # Merge nested settings carefully
                for subkey, subvalue in value.items():
                    if subkey not in default_config[key]:
                        default_config[key][subkey] = subvalue
        
        # Write merged config
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
    
    # Use environment variables to safely pass values to Python
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
    
    # Clean up environment variables
    unset KIOSK_KEY_PATH KIOSK_DEFAULT_VALUE
}

set_config_value() {
    local key_path="$1"
    local new_value="$2"
    
    # Use environment variables to safely pass values to Python
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

    # Handle different value types
    if new_value.lower() == 'true':
        current[keys[-1]] = True
    elif new_value.lower() == 'false': 
        current[keys[-1]] = False
    elif new_value.isdigit():
        current[keys[-1]] = int(new_value)
    else:
        current[keys[-1]] = new_value

    # Write to temporary file first, then move to prevent corruption
    import tempfile
    import os
    
    temp_file = config_file + '.tmp'
    with open(temp_file, 'w') as f:
        json.dump(data, f, indent=2)
    
    # Verify the temp file is valid JSON
    with open(temp_file, 'r') as f:
        json.load(f)  # This will raise an exception if invalid
    
    # Replace the original file
    os.replace(temp_file, config_file)
    
    print('SUCCESS')
    
except Exception as e:
    print(f'ERROR: Failed to update config: {e}', file=sys.stderr)
    print(f'DEBUG: Config file path was: {config_file}', file=sys.stderr)
    # Don't exit - that might be causing corruption, just report the error
    print('FAILED')
" || {
        log_error "Failed to update configuration file"
        return 1
    }
    
    # Clean up environment variables
    unset KIOSK_CONFIG_FILE KIOSK_KEY_PATH KIOSK_NEW_VALUE
    
    log_debug "Configuration updated successfully"
}

get_browser_memory_kb() {
    local chromium_pids
    chromium_pids=$(pgrep -f chromium 2>/dev/null)
    
    if [[ -z "$chromium_pids" ]]; then
        echo "0"
        return
    fi
    
    # Use RSS (Resident Set Size) instead of VSZ to avoid counting shared memory multiple times
    # RSS is the actual physical memory usage
    local memory_kb
    memory_kb=$(echo "$chromium_pids" | xargs -r ps -o rss= -p 2>/dev/null | awk '{sum+=$1} END {printf "%.0f", sum+0}')
    
    # Validate memory calculation - if it's unreasonably high (>10GB), it's likely a calculation error
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
    
    # Validate required sections - be more lenient
    if 'kiosk' not in data:
        exit(1)
    
    # Validate kiosk section has at least url
    if 'url' not in data['kiosk']:
        exit(1)
        
    exit(0)
except:
    exit(1)
"
}

# ==========================================
# PLAYLIST MANAGEMENT FUNCTIONS
# ==========================================

# Legacy function - now uses unified config
create_default_playlist() {
    create_default_config
}

get_playlist_config() {
    get_config_value "playlist"
}

is_playlist_enabled() {
    get_config_value "playlist.enabled" "false"
}

get_playlist_urls() {
    local config
    config=$(get_playlist_config)
    
    python3 -c "
import json
try:
    data = json.loads('$config')
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
        get_url  # Fallback to single URL mode
        return
    fi
    
    local total_urls
    total_urls=$(echo "$urls_info" | wc -l)
    
    # Get current index from state file
    local current_index=0
    if [[ -f "/tmp/kiosk-playlist-index" ]]; then
        current_index=$(cat "/tmp/kiosk-playlist-index" 2>/dev/null || echo "0")
    fi
    
    # Wrap around if index is out of bounds
    if [[ $current_index -ge $total_urls ]]; then
        current_index=0
    fi
    
    # Get URL info for current index
    local url_info
    url_info=$(echo "$urls_info" | sed -n "$((current_index + 1))p")
    
    if [[ -n "$url_info" ]]; then
        echo "$url_info" | cut -d'|' -f2
    else
        get_url  # Fallback to single URL mode
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
    
    # Advance to next URL
    current_index=$((current_index + 1))
    
    # Wrap around if at end
    if [[ $current_index -ge $total_urls ]]; then
        current_index=0
    fi
    
    # Save new index
    echo "$current_index" > "/tmp/kiosk-playlist-index"
    
    log_debug "Advanced playlist to index: $current_index"
}

start_playlist_rotation() {
    log_info "Starting playlist rotation..."
    
    while true; do
        local current_url
        current_url=$(get_current_playlist_url)
        
        local display_time
        display_time=$(get_current_playlist_display_time)
        
        log_info "Displaying URL: $current_url for ${display_time}s"
        
        # Navigate browser to current URL
        navigate_browser_to_url "$current_url"
        
        # Wait for display time
        sleep "$display_time"
        
        # Advance to next URL
        advance_playlist
        
        # Check if playlist is still enabled
        if [[ "$(is_playlist_enabled)" != "true" ]]; then
            log_info "Playlist disabled, stopping rotation"
            break
        fi
    done
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
    fi
    
    log_debug "Attempting DevTools navigation to: $url"
    
    # Test DevTools connectivity with retries
    local devtools_test
    local retry_count=0
    local max_retries=5
    
    while [[ $retry_count -lt $max_retries ]]; do
        devtools_test=$(curl -s --connect-timeout 2 "http://localhost:$DEBUG_PORT/json" 2>/dev/null)
        if [[ -n "$devtools_test" ]]; then
            log_debug "DevTools connected on attempt $((retry_count + 1))"
            break
        fi
        ((retry_count++))
        log_debug "DevTools attempt $retry_count/$max_retries failed, retrying..."
        sleep 1
    done
    
    if [[ -z "$devtools_test" ]]; then
        log_warn "DevTools not accessible on port $DEBUG_PORT after $max_retries attempts"
        return 1
    fi
    
    # Get the first tab ID
    local tab_id
    tab_id=$(echo "$devtools_test" | python3 -c "
import json, sys
try:
    tabs = json.load(sys.stdin)
    if tabs and len(tabs) > 0:
        print(tabs[0]['id'])
    else:
        print('ERROR: No tabs found')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)
    
    if [[ "$tab_id" == "ERROR:"* ]] || [[ -z "$tab_id" ]]; then
        log_warn "Could not get tab ID from DevTools"
        return 1
    fi
    
    log_debug "Found tab ID: $tab_id"
    
    # Try simple navigation using Runtime.evaluate
    local nav_result
    nav_result=$(python3 -c "
import json
import urllib.request

url = '$url'
tab_id = '$tab_id'
debug_port = $DEBUG_PORT

try:
    # Simple JavaScript navigation command
    js_code = f'window.location.href = \"{url}\";'
    
    # Send Runtime.evaluate command via POST
    payload = {
        'id': 1,
        'method': 'Runtime.evaluate',
        'params': {
            'expression': js_code
        }
    }
    
    devtools_url = f'http://localhost:{debug_port}/json/runtime/evaluate'
    req = urllib.request.Request(
        devtools_url,
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    
    with urllib.request.urlopen(req, timeout=10) as response:
        result = response.read().decode()
        print('SUCCESS')
        
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)
    
    if [[ "$nav_result" == "SUCCESS" ]]; then
        log_info "DevTools navigation successful"
        return 0
    else
        log_warn "DevTools navigation failed: $nav_result"
        return 1
    fi
}


try:
    # Send the command
    devtools_url = f'http://localhost:{debug_port}/json/runtime/evaluate'
    req = urllib.request.Request(
        devtools_url, 
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    
    with urllib.request.urlopen(req, timeout=5) as response:
        result = response.read().decode()
        print('SUCCESS')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)
                
                if [[ "$nav_payload" == "SUCCESS" ]]; then
import json
import urllib.request
import urllib.parse
import os
import sys

url_to_navigate = os.environ['NAVIGATE_URL']
tab_id = '$tab_info'
debug_port = '$DEBUG_PORT'

print(f'DEBUG: Navigating to {url_to_navigate} on tab {tab_id} port {debug_port}', file=sys.stderr)

# Method 1: Simple HTTP-based navigation for Chromium
try:
    # Method 1a: Try direct URL navigation via GET to /json/new
    encoded_url = urllib.parse.quote(url_to_navigate, safe='')
    new_tab_url = f'http://localhost:{debug_port}/json/new?{encoded_url}'
    print(f'DEBUG: Trying GET new tab: {new_tab_url}', file=sys.stderr)
    
    req = urllib.request.Request(new_tab_url)
    with urllib.request.urlopen(req, timeout=5) as response:
        new_result = response.read().decode()
        print(f'DEBUG: New tab response: {new_result}', file=sys.stderr)
        
        if new_result and ('id' in new_result or 'webSocketDebuggerUrl' in new_result):
            # Close the old tab after successful creation
            try:
                close_url = f'http://localhost:{debug_port}/json/close/{tab_id}'
                close_req = urllib.request.Request(close_url)
                urllib.request.urlopen(close_req, timeout=2)
                print(f'DEBUG: Closed old tab {tab_id}', file=sys.stderr)
            except:
                pass  # Don't fail if close doesn't work
            print('SUCCESS')
        else:
            raise Exception('New tab creation failed')
            
except Exception as e:
    print(f'DEBUG: Method 1a failed: {e}', file=sys.stderr)
    
    # Method 1b: Try activate existing tab + navigate via runtime
    try:
        # Activate the tab first
        activate_url = f'http://localhost:{debug_port}/json/activate/{tab_id}'
        print(f'DEBUG: Activating tab: {activate_url}', file=sys.stderr)
        
        req = urllib.request.Request(activate_url)
        urllib.request.urlopen(req, timeout=5)
        
        import time
        time.sleep(0.2)
        
        # Now try to navigate via runtime evaluate using GET
        # Use double quotes to avoid single quote escaping issues
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
        
        # Method 1c: Simple approach - just create new tab without closing old one
        try:
            simple_url = f'http://localhost:{debug_port}/json/new'
            print(f'DEBUG: Simple new tab: {simple_url}', file=sys.stderr)
            
            req = urllib.request.Request(simple_url, method='PUT')
            req.add_header('Content-Type', 'text/plain')
            
            with urllib.request.urlopen(req, data=url_to_navigate.encode('utf-8'), timeout=5) as response:
                simple_result = response.read().decode()
                print(f'DEBUG: Simple response: {simple_result}', file=sys.stderr)
                
                if simple_result and ('id' in simple_result):
                    # Parse the new tab info and navigate it via WebSocket
                    import json as json_module
                    new_tab_data = json_module.loads(simple_result)
                    new_tab_id = new_tab_data['id']
                    
                    # Close the old tab to ensure only one tab is open
                    try:
                        close_url = f'http://localhost:{debug_port}/json/close/{tab_id}'
                        close_req = urllib.request.Request(close_url)
                        urllib.request.urlopen(close_req, timeout=2)
                        print(f'DEBUG: Closed old tab {tab_id}', file=sys.stderr)
                    except:
                        pass  # Don't fail if close doesn't work
                    
                    # Now use WebSocket to navigate this new tab
                    try:
                        print(f'DEBUG: Attempting to import websocket library', file=sys.stderr)
                        import websocket
                        print(f'DEBUG: WebSocket library imported successfully', file=sys.stderr)
                        
                        ws_url = f'ws://localhost:{debug_port}/devtools/page/{new_tab_id}'
                        print(f'DEBUG: Using WebSocket to navigate new tab: {ws_url}', file=sys.stderr)
                        
                        def on_open(ws):
                            print(f'DEBUG: WebSocket connection opened', file=sys.stderr)
                            # First enable Page domain
                            enable_cmd = {
                                'id': 1,
                                'method': 'Page.enable'
                            }
                            print(f'DEBUG: Sending Page.enable command', file=sys.stderr)
                            ws.send(json_module.dumps(enable_cmd))
                            
                            # Then navigate
                            nav_cmd = {
                                'id': 2,
                                'method': 'Page.navigate',
                                'params': {'url': url_to_navigate}
                            }
                            print(f'DEBUG: Sending Page.navigate command to {url_to_navigate}', file=sys.stderr)
                            ws.send(json_module.dumps(nav_cmd))
                        
                        def on_error(ws, error):
                            print(f'DEBUG: WebSocket error: {error}', file=sys.stderr)
                            # Don't print FAILED here - let the exception handler deal with it
                        
                        def on_close(ws, close_status_code, close_msg):
                            print(f'DEBUG: WebSocket closed: {close_status_code} {close_msg}', file=sys.stderr)
                        
                        def on_message(ws, message):
                            result = json_module.loads(message)
                            print(f'DEBUG: WebSocket response: {result}', file=sys.stderr)
                            if 'result' in result and result.get('id') == 2:
                                # This is the response to our navigate command
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
                        
                        # If we get here and no SUCCESS was printed, WebSocket failed
                        raise Exception('WebSocket navigation failed')
                        
                    except ImportError:
                        print(f'DEBUG: WebSocket library not available', file=sys.stderr)
                        # Fallback: try a simple HTTP-based navigation on the new tab
                        try:
                            # Try to use a direct navigation approach
                            time.sleep(0.5)  # Give the new tab time to initialize
                            
                            # Method: Send navigation via the tab's specific endpoint
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
                        # Fallback: try a simple HTTP-based navigation on the new tab
                        try:
                            # Try to use a direct navigation approach
                            import time
                            time.sleep(0.5)  # Give the new tab time to initialize
                            
                            # Method: Send navigation via the tab's specific endpoint
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
    
# All methods attempted, if we get here it means all failed
print('FAILED')
" 2>&1)
                unset NAVIGATE_URL
                
                log_debug "Navigation result: $nav_result"
                
                # Check if any line contains SUCCESS
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
    
    # Fallback: restart browser with new URL (less efficient)
    log_warn "Could not navigate via DevTools, restarting browser"
    start_browser_process "$url"
}

add_playlist_url() {
    local url="$1"
    local display_time="${2:-$DEFAULT_DISPLAY_TIME}"
    local title="${3:-}"
    local mode="${4:-add}"  # add or replace
    
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
    
    # If no title provided, use URL hostname
    if [[ -z "$title" ]]; then
        title=$(echo "$url" | sed -E 's|^https?://([^/]+).*|\1|')
    fi
    
    backup_config
    
    # Add new URL using unified config
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

config = json.loads('$config')
urls = config.get('urls', [])

if $index < len(urls):
    removed = urls.pop($index)
    print(f\"Removed: {removed.get('title', 'Unknown')} - {removed.get('url', '')}\")
    
    with open('$PLAYLIST_CONFIG_FILE', 'w') as f:
        json.dump(config, f, indent=2)
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

config = json.loads('$config')
config['enabled'] = True

with open('$PLAYLIST_CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2)
" || {
        log_error "Failed to enable playlist"
        return 1
    }
    
    log_info "Playlist mode enabled"
}

disable_playlist() {
    backup_config
    
    local config
    config=$(get_playlist_config)
    
    python3 -c "
import json

config = json.loads('$config')
config['enabled'] = False

with open('$PLAYLIST_CONFIG_FILE', 'w') as f:
    json.dump(config, f, indent=2)
" || {
        log_error "Failed to disable playlist"
        return 1
    }
    
    # Reset playlist index
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
            
            ((index++))
        done <<< "$urls_info"
        
        echo "Commands:"
        echo "  kiosk playlist-add <URL> [time] [title]  - Add URL"
        echo "  kiosk playlist-remove <index>           - Remove URL"
        echo "  kiosk playlist-enable                   - Enable rotation"
        echo "  kiosk playlist-disable                  - Disable rotation"
    fi
    
    echo "========================================"
}

backup_config() {
    local backup_dir="$INSTALL_DIR/backups"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    
    mkdir -p "$backup_dir" 2>/dev/null || return 1
    
    for config in "$CONFIG_FILE" "$API_CONFIG_FILE" "$ROTATION_CONFIG_FILE" "$PLAYLIST_CONFIG_FILE"; do
        if [[ -f "$config" ]]; then
            local filename=$(basename "$config")
            cp "$config" "$backup_dir/${filename}.${timestamp}" 2>/dev/null || {
                log_warn "Failed to backup: $config"
                continue
            }
            log_debug "Backed up: $config"
        fi
    done
    
    # Keep only last 10 backups
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
    
    # Find most recent backup
    local latest_backup
    latest_backup=$(find "$backup_dir" -name "${config_name}.*" -type f | sort -r | head -1)
    
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
            target_file="$API_CONFIG_FILE"
            ;;
        "rotation_config.txt")
            target_file="$ROTATION_CONFIG_FILE"
            ;;
        "playlist_config.json")
            target_file="$PLAYLIST_CONFIG_FILE"
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

# Browser health monitoring and crash recovery
monitor_browser_health() {
    local max_memory_kb=$BROWSER_MEMORY_LIMIT
    local restart_count=0
    
    while true; do
        sleep $HEALTH_CHECK_INTERVAL
        
        # Check if browser is running
        if ! pgrep -f chromium >/dev/null; then
            log_warn "Browser not running, attempting restart..."
            recover_browser
            ((restart_count++))
            
            if [[ $restart_count -ge $BROWSER_RESTART_THRESHOLD ]]; then
                log_critical "Browser restarted $restart_count times, may need manual intervention"
                save_debug_state
                restart_count=0  # Reset counter to prevent spam
            fi
            continue
        fi
        
        # Check memory usage
        local browser_memory
        browser_memory=$(get_browser_memory_kb)
        
        if [[ $browser_memory -gt $max_memory_kb ]]; then
            log_warn "Browser memory usage high: ${browser_memory}KB > ${max_memory_kb}KB, restarting..."
            recover_browser
            ((restart_count++))
        fi
        
        # Check if X server is responsive
        if ! timeout 5 xdpyinfo -display :0 >/dev/null 2>&1; then
            log_warn "X server not responsive, attempting display recovery..."
            recover_display
        fi
        
        # Log health status periodically
        if [[ $(($(date +%s) % 300)) -eq 0 ]]; then  # Every 5 minutes
            log_debug "Health check: Browser running, Memory: ${browser_memory}KB"
        fi
    done
}

# Enhanced browser management with crash detection
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
    
    # Start browser monitoring in background
    monitor_browser_health &
    local monitor_pid=$!
    echo $monitor_pid > /tmp/kiosk-monitor.pid
    
    # Start the actual browser
    start_browser_process "$url"
}

start_browser_process() {
    local url="$1"
    
    # Kill existing processes
    pkill -f chromium 2>/dev/null || true
    sleep 2
    pkill -9 -f chromium 2>/dev/null || true
    
    # Clean up temp files
    rm -rf /tmp/chromium-kiosk 2>/dev/null || true
    
    # Wait for X to be ready with timeout
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
    
    # Start browser with architecture-specific flags
    local browser_cmd
    if [[ "$IS_ARM" == true ]]; then
        browser_cmd="$CHROMIUM_PATH --no-first-run --no-default-browser-check --disable-default-apps --disable-popup-blocking --disable-translate --disable-background-timer-throttling --disable-renderer-backgrounding --disable-device-discovery-notifications --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --noerrdialogs --kiosk --start-maximized --disable-gpu-sandbox --use-gl=egl --enable-gpu-rasterization --disable-web-security --disable-features=TranslateUI --no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage --memory-pressure-off --max_old_space_size=512 --display=:0 --remote-debugging-port=$DEBUG_PORT --remote-allow-origins=* --user-data-dir=/tmp/chromium-kiosk"
        
        if [[ "$IS_RPI" == true ]]; then
            browser_cmd="$browser_cmd --disable-features=VizDisplayCompositor --disable-smooth-scrolling --disable-2d-canvas-clip-aa --disable-canvas-aa --disable-accelerated-2d-canvas"
        fi
    else
        browser_cmd="$CHROMIUM_PATH --no-first-run --no-default-browser-check --disable-default-apps --disable-popup-blocking --disable-translate --disable-background-timer-throttling --disable-renderer-backgrounding --disable-device-discovery-notifications --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --noerrdialogs --kiosk --start-maximized --disable-gpu --disable-software-rasterizer --disable-web-security --disable-features=TranslateUI,VizDisplayCompositor --disable-ipc-flooding-protection --no-sandbox --disable-setuid-sandbox --force-device-scale-factor=1 --display=:0 --remote-debugging-port=$DEBUG_PORT --remote-allow-origins=* --user-data-dir=/tmp/chromium-kiosk"
    fi
    
    browser_cmd="$browser_cmd \"$url\""
    
    log_debug "Starting browser: $browser_cmd"
    
    # Start browser in background with error handling
    eval "$browser_cmd" &
    local browser_pid=$!
    echo $browser_pid > /tmp/kiosk-browser.pid
    
    # Give browser time to start
    sleep 5
    
    # Verify browser started successfully
    if ! kill -0 $browser_pid 2>/dev/null; then
        log_error "Browser failed to start (PID $browser_pid)"
        return 1
    fi
    
    log_info "Browser started successfully (PID $browser_pid)"
    return 0
}

# System health checks
check_system_health() {
    local issues=()
    
    # Check disk space
    local disk_usage
    disk_usage=$(df /opt/kiosk | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        issues+=("High disk usage: ${disk_usage}%")
    fi
    
    # Check memory usage
    local mem_usage
    mem_usage=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100)}')
    if [[ $mem_usage -gt 90 ]]; then
        issues+=("High memory usage: ${mem_usage}%")
    fi
    
    # Check if critical services are running
    for service in kiosk.service kiosk-api.service; do
        if ! systemctl is-active "$service" >/dev/null 2>&1; then
            issues+=("Service not running: $service")
        fi
    done
    
    # Check if X server is responsive
    if ! timeout 5 xdpyinfo -display :0 >/dev/null 2>&1; then
        issues+=("X server not responsive")
    fi
    
    # Check if browser is running
    if ! pgrep -f chromium >/dev/null; then
        issues+=("Browser not running")
    fi
    
    # Check configuration files
    for config_file in "$CONFIG_FILE" "$API_CONFIG_FILE" "$ROTATION_CONFIG_FILE"; do
        if [[ ! -f "$config_file" ]]; then
            issues+=("Missing config file: $(basename "$config_file")")
        fi
    done
    
    return ${#issues[@]}
}

get_system_health_report() {
    local issues=()
    
    # Collect system information
    echo "=== KIOSK SYSTEM HEALTH REPORT ==="
    echo "Timestamp: $(date)"
    echo "Architecture: $ARCH"
    [[ "$IS_RPI" == true ]] && echo "Raspberry Pi: Yes"
    echo
    
    # Disk space
    echo "=== DISK USAGE ==="
    df -h / 2>/dev/null || echo "Disk info unavailable"
    echo
    
    # Memory usage
    echo "=== MEMORY USAGE ==="
    free -h
    echo
    
    # Services status
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
    
    # Process information
    echo "=== PROCESSES ==="
    echo "X Server: $(pgrep Xorg >/dev/null && echo "RUNNING" || echo "STOPPED")"
    echo "Browser: $(pgrep -f chromium >/dev/null && echo "RUNNING" || echo "STOPPED")"
    echo "Window Manager: $(pgrep openbox >/dev/null && echo "RUNNING" || echo "STOPPED")"
    echo
    
    # Browser memory usage
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
    
    # Configuration status
    echo "=== CONFIGURATION ==="
    echo "URL: $(get_url 2>/dev/null || echo "ERROR")"
    echo "Rotation: $(get_rotation 2>/dev/null || echo "ERROR")"
    echo "API Key: $(get_api_key 2>/dev/null | cut -c1-8)..."
    echo
    
    # Network status
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
    
    # Issues summary
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
    
    # Always return 0 for health check - this is informational only
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

# ==========================================
# SETUP FUNCTIONS
# ==========================================

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
    if [[ "$IS_RPI" == true ]]; then
        if command -v raspi-config >/dev/null; then
            log_info "Configuring Raspberry Pi GPU memory split..."
            echo "gpu_mem=128" >> /boot/config.txt 2>/dev/null || true
        fi
    fi
    
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
    
    local api_key
    api_key=$(get_config_value "api.api_key" "default-key")
    
    cat > "$INSTALL_DIR/USAGE_EXAMPLES.md" << 'EOF'
# Kiosk System Usage Examples

This file contains comprehensive examples for managing your kiosk system using both local commands and remote API calls.

## Local Command Usage

### Basic System Management

```bash
# Check system status
kiosk status

# Show detailed system health
kiosk health

# Monitor system in real-time
kiosk monitor

# Show system version and info
kiosk version

# Restart kiosk service
sudo kiosk restart

# Stop kiosk service  
sudo kiosk stop

# Start kiosk service
sudo kiosk start
```

### Single URL Management

```bash
# Set a single URL (displays indefinitely)
kiosk set-url http://google.com

# Get current URL
kiosk get-url

# Set URL with immediate display
kiosk set-url https://dashboard.example.com
```

### Screen Rotation

```bash
# Set screen rotation
kiosk set-rotation left        # Rotate 90° left
kiosk set-rotation right       # Rotate 90° right  
kiosk set-rotation inverted    # Rotate 180°
kiosk set-rotation normal      # No rotation

# Get current rotation
kiosk get-rotation
```

### Playlist Management

```bash
# Show current playlist
kiosk playlist

# Add URLs to playlist (keeps existing URLs)
kiosk playlist-add http://google.com 60 "Google Search"
kiosk playlist-add http://github.com 45 "GitHub"
kiosk playlist-add http://stackoverflow.com 30

# Replace entire playlist with new URLs
kiosk playlist-replace http://newsite.com 120 "New Site Only"
kiosk playlist-set http://dashboard.com 300 "Dashboard Only"

# Remove specific URL by index
kiosk playlist-remove 1

# Enable playlist rotation
kiosk playlist-enable

# Disable playlist (single URL mode)
kiosk playlist-disable

# Clear playlist to default
sudo kiosk playlist-clear
```

### API Key Management

```bash
# Show current API key
kiosk get-api-key

# Generate new API key
sudo kiosk regenerate-api-key
```

### Configuration Management

```bash
# Backup current configuration
sudo kiosk backup-config

# Restore configuration from backup
sudo kiosk restore-config backup-20231201-120000.tar.gz

# Validate all configurations
kiosk validate-config
```

### System Maintenance

```bash
# View service logs
kiosk logs            # Both services
kiosk logs kiosk      # Kiosk service only
kiosk logs api        # API service only

# Clean old log files
sudo kiosk clean-logs

# Collect debug information
kiosk debug

# Test API endpoints
kiosk test-api
```

### Browser Maintenance

```bash
# Check which Chromium installation method is used
kiosk version    # Shows installation method and correct update command

# Check current Chromium version
chromium --version 2>/dev/null || chromium-browser --version 2>/dev/null || echo "Chromium not found"

# === UPDATE CHROMIUM ===

# For APT installation (Debian/Ubuntu 20.04 and earlier):
sudo apt update && sudo apt upgrade chromium-browser -y && sudo kiosk restart

# For Snap installation (Ubuntu 22.04+):
sudo snap refresh chromium && sudo kiosk restart

# === TROUBLESHOOTING ===

# Force reinstall Chromium (APT method)
sudo apt remove chromium-browser -y && sudo apt install chromium-browser -y

# Force reinstall Chromium (Snap method)  
sudo snap remove chromium && sudo snap install chromium

# Clear Chromium cache and data (run as kiosk user)
sudo -u kiosk rm -rf /opt/kiosk/.cache/chromium/ 2>/dev/null
sudo -u kiosk rm -rf /opt/kiosk/.config/chromium/ 2>/dev/null

# Restart kiosk after browser maintenance
sudo kiosk restart
```

## Remote API Usage

**Base URL**: `http://YOUR-KIOSK-IP/`
**Authentication**: Add `?api_key=YOUR-API-KEY` to all requests

### System Status

```bash
# Get system status
curl "http://192.168.1.100/status?api_key=YOUR_API_KEY"

# Response example:
{
  "status": "running",
  "current_url": "http://google.com",
  "playlist_enabled": false,
  "rotation": "normal",
  "browser_running": true
}
```

### Single URL Management

```bash
# Set single URL (disables playlist mode)
curl -X POST "http://192.168.1.100/set-url?api_key=YOUR_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"url": "http://google.com"}'

# Response:
{
  "status": "success",
  "url": "http://google.com",
  "mode": "single"
}
```

### Multiple URL Playlist

```bash
# Replace playlist with multiple URLs
curl -X POST "http://192.168.1.100/set-url?api_key=YOUR_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{
       "urls": [
         {
           "url": "http://google.com",
           "duration": 60,
           "title": "Google Search"
         },
         {
           "url": "http://github.com", 
           "duration": 45,
           "title": "GitHub"
         },
         {
           "url": "http://stackoverflow.com",
           "duration": 30,
           "title": "Stack Overflow"
         }
       ]
     }'

# Simple URL list (30s default duration)
curl -X POST "http://192.168.1.100/set-url?api_key=YOUR_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{
       "urls": [
         "http://site1.com",
         "http://site2.com", 
         "http://site3.com"
       ]
     }'

# Response example:
{
  "status": "success",
  "mode": "playlist",
  "urls": [
    {"url": "http://google.com", "duration": 60, "title": "Google Search"},
    {"url": "http://github.com", "duration": 45, "title": "GitHub"}
  ]
}
```

### Screen Rotation

```bash
# Set screen rotation
curl -X POST "http://192.168.1.100/set-rotation?api_key=YOUR_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"rotation": "left"}'

# Valid rotations: normal, left, right, inverted
```

### System Control

```bash
# Restart kiosk service
curl -X POST "http://192.168.1.100/restart?api_key=YOUR_API_KEY"

# Reboot entire system
curl -X POST "http://192.168.1.100/reboot?api_key=YOUR_API_KEY"
```

## Programming Examples

### Python Script

```python
import requests
import json

# Configuration
KIOSK_IP = "192.168.1.100"
API_KEY = "your-api-key-here"
BASE_URL = f"http://{KIOSK_IP}"

def set_single_url(url):
    """Set a single URL (disables playlist)"""
    response = requests.post(
        f"{BASE_URL}/set-url?api_key={API_KEY}",
        headers={"Content-Type": "application/json"},
        json={"url": url}
    )
    return response.json()

def set_playlist(urls):
    """Set multiple URLs with rotation"""
    response = requests.post(
        f"{BASE_URL}/set-url?api_key={API_KEY}",
        headers={"Content-Type": "application/json"},
        json={"urls": urls}
    )
    return response.json()

def get_status():
    """Get current kiosk status"""
    response = requests.get(f"{BASE_URL}/status?api_key={API_KEY}")
    return response.json()

# Examples
print("Setting single URL...")
result = set_single_url("http://google.com")
print(result)

print("Setting playlist...")
playlist = [
    {"url": "http://google.com", "duration": 60, "title": "Google"},
    {"url": "http://github.com", "duration": 45, "title": "GitHub"}
]
result = set_playlist(playlist)
print(result)

print("Getting status...")
status = get_status()
print(status)
```

### Shell Script Automation

```bash
#!/bin/bash
# Kiosk automation script

KIOSK_IP="192.168.1.100"
API_KEY="your-api-key-here"

# Function to set URL
set_kiosk_url() {
    curl -s -X POST "http://$KIOSK_IP/set-url?api_key=$API_KEY" \
         -H "Content-Type: application/json" \
         -d "{\"url\": \"$1\"}"
}

# Function to check status
check_status() {
    curl -s "http://$KIOSK_IP/status?api_key=$API_KEY"
}

# Schedule different URLs throughout the day
case $(date +%H) in
    06|07|08) set_kiosk_url "http://morning-dashboard.com" ;;
    12|13)    set_kiosk_url "http://lunch-menu.com" ;;
    17|18)    set_kiosk_url "http://evening-news.com" ;;
    *)        set_kiosk_url "http://default-display.com" ;;
esac

echo "Status: $(check_status)"
```

### Node.js Example

```javascript
const axios = require('axios');

class KioskManager {
    constructor(ip, apiKey) {
        this.baseUrl = `http://${ip}`;
        this.apiKey = apiKey;
    }

    async setUrl(url) {
        try {
            const response = await axios.post(
                `${this.baseUrl}/set-url?api_key=${this.apiKey}`,
                { url },
                { headers: { 'Content-Type': 'application/json' } }
            );
            return response.data;
        } catch (error) {
            console.error('Error setting URL:', error.message);
        }
    }

    async setPlaylist(urls) {
        try {
            const response = await axios.post(
                `${this.baseUrl}/set-url?api_key=${this.apiKey}`,
                { urls },
                { headers: { 'Content-Type': 'application/json' } }
            );
            return response.data;
        } catch (error) {
            console.error('Error setting playlist:', error.message);
        }
    }

    async getStatus() {
        try {
            const response = await axios.get(
                `${this.baseUrl}/status?api_key=${this.apiKey}`
            );
            return response.data;
        } catch (error) {
            console.error('Error getting status:', error.message);
        }
    }
}

// Usage
const kiosk = new KioskManager('192.168.1.100', 'your-api-key');

// Set single URL
kiosk.setUrl('http://dashboard.example.com')
    .then(result => console.log('URL set:', result));

// Set playlist
const playlist = [
    { url: 'http://site1.com', duration: 30, title: 'Site 1' },
    { url: 'http://site2.com', duration: 60, title: 'Site 2' }
];

kiosk.setPlaylist(playlist)
    .then(result => console.log('Playlist set:', result));
```

## Common Use Cases

### Digital Signage
```bash
# Morning announcements
kiosk set-url http://announcements.company.com

# Rotating company dashboards  
kiosk playlist-replace http://sales-dashboard.com 300 "Sales Dashboard"
kiosk playlist-add http://hr-dashboard.com 300 "HR Dashboard"
kiosk playlist-add http://news.company.com 120 "Company News"
kiosk playlist-enable
```

### Information Display
```bash
# Weather and news rotation
kiosk playlist-replace http://weather.local 180 "Weather"
kiosk playlist-add http://news.local 120 "News"  
kiosk playlist-add http://calendar.local 60 "Calendar"
kiosk playlist-enable
```

### Restaurant Menu Board
```bash
# Breakfast menu (6 AM - 11 AM)
kiosk set-url http://menu.restaurant.com/breakfast

# Lunch menu (11 AM - 5 PM)  
kiosk set-url http://menu.restaurant.com/lunch

# Dinner menu (5 PM - 10 PM)
kiosk set-url http://menu.restaurant.com/dinner
```

## Troubleshooting

### Check System Status
```bash
kiosk status
kiosk health
kiosk logs
```

### Reset to Default
```bash
sudo kiosk stop
sudo kiosk playlist-clear  
kiosk set-url http://example.com
sudo kiosk start
```

### Network Issues
```bash
# Test API connectivity
curl -v "http://YOUR-KIOSK-IP/status?api_key=YOUR_API_KEY"

# Check if services are running
sudo systemctl status kiosk.service
sudo systemctl status kiosk-api.service
```

EOF

    # Replace placeholder with actual API key
    sed -i "s/YOUR_API_KEY/$api_key/g" "$INSTALL_DIR/USAGE_EXAMPLES.md"
    sed -i "s/your-api-key-here/$api_key/g" "$INSTALL_DIR/USAGE_EXAMPLES.md"
    
    chmod 644 "$INSTALL_DIR/USAGE_EXAMPLES.md"
    
    log_info "Usage examples file created at $INSTALL_DIR/USAGE_EXAMPLES.md"
}

create_kiosk_script() {
    log_info "Creating kiosk startup script..."
    
    cat > "$INSTALL_DIR/start_kiosk.sh" << EOF
#!/bin/bash
set -e

# Start X server as root if not running
if ! pgrep Xorg >/dev/null; then
    echo "Starting X server as root..."
    X :0 -nolisten tcp -noreset +extension GLX vt1 &
    sleep 3
    
    # Set permissions
    xhost +local: 2>/dev/null || true
    xhost +local:$KIOSK_USER 2>/dev/null || true
    chown $KIOSK_USER:$KIOSK_USER /tmp/.X11-unix/X0 2>/dev/null || true
    chmod 666 /tmp/.X11-unix/X0 2>/dev/null || true
fi

export DISPLAY=:0
export HOME=$INSTALL_DIR
cd $INSTALL_DIR

# Wait for X to be ready
for i in {1..30}; do
    if xdpyinfo -display :0 >/dev/null 2>&1; then
        echo "X server is ready"
        break
    fi
    sleep 1
done

# Disable screen blanking
./disable_blanking.sh

# Start window manager
if ! pgrep openbox >/dev/null; then
    echo "Starting Openbox..."
    openbox &
    sleep 2
fi

# Hide cursor
if ! pgrep unclutter >/dev/null; then
    echo "Starting unclutter..."
    unclutter -display :0 -idle 1 -root &
    sleep 1
fi

# Set black background
xsetroot -solid black 2>/dev/null || true

# Apply saved rotation from unified config
if [[ -f "$CONFIG_FILE" ]]; then
    ROTATION=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
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

# Check if playlist mode is enabled from unified config
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

# Kill existing chromium
pkill -f chromium 2>/dev/null || true
sleep 2

if [[ "\$PLAYLIST_ENABLED" == "true" ]]; then
    echo "Starting browser in playlist mode..."
    # Start with first URL from playlist
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
    
    # Reset playlist index
    echo "0" > /tmp/kiosk-playlist-index
else
    # Single URL mode
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

# Architecture-specific browser flags
if [[ "$IS_ARM" == true ]]; then
    BROWSER_FLAGS="--no-first-run --no-default-browser-check --disable-default-apps --disable-popup-blocking --disable-translate --disable-background-timer-throttling --disable-renderer-backgrounding --disable-device-discovery-notifications --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --noerrdialogs --kiosk --start-maximized --disable-gpu-sandbox --use-gl=egl --enable-gpu-rasterization --disable-web-security --disable-features=TranslateUI --no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage --memory-pressure-off --max_old_space_size=512 --display=:0 --remote-debugging-port=$DEBUG_PORT --remote-allow-origins=* --user-data-dir=/tmp/chromium-kiosk"
    
    if [[ "$IS_RPI" == true ]]; then
        BROWSER_FLAGS="\$BROWSER_FLAGS --disable-features=VizDisplayCompositor --disable-smooth-scrolling --disable-2d-canvas-clip-aa --disable-canvas-aa --disable-accelerated-2d-canvas"
    fi
else
    BROWSER_FLAGS="--no-first-run --no-default-browser-check --disable-default-apps --disable-popup-blocking --disable-translate --disable-background-timer-throttling --disable-renderer-backgrounding --disable-device-discovery-notifications --disable-infobars --disable-session-crashed-bubble --disable-restore-session-state --noerrdialogs --kiosk --start-maximized --disable-gpu --disable-software-rasterizer --disable-web-security --disable-features=TranslateUI,VizDisplayCompositor --disable-ipc-flooding-protection --no-sandbox --disable-setuid-sandbox --force-device-scale-factor=1 --display=:0 --remote-debugging-port=$DEBUG_PORT --remote-allow-origins=* --user-data-dir=/tmp/chromium-kiosk"
fi

# Start browser with architecture-specific flags
$CHROMIUM_PATH \$BROWSER_FLAGS "\$URL" &
BROWSER_PID=\$!
echo \$BROWSER_PID > /tmp/kiosk-browser.pid

# Start playlist rotation in background if enabled
if [[ "\$PLAYLIST_ENABLED" == "true" ]]; then
    echo "Starting playlist rotation service..."
    (
        sleep 10  # Wait for browser to fully start
        while true; do
            # Get current display time from unified config
            DISPLAY_TIME=\$(python3 -c "
import json
try:
    with open('$CONFIG_FILE', 'r') as f:
        data = json.load(f)
    urls = data.get('playlist', {}).get('urls', [])
    
    # Get current index
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
            
            # Check if playlist is still enabled and has multiple URLs
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
            
            # Advance to next URL and navigate
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
    with open('$PLAYLIST_CONFIG_FILE', 'r') as f:
        data = json.load(f)
    total_urls = len(data.get('urls', []))
    
    if total_urls > 1:
        # Advance index
        current_index = (current_index + 1) % total_urls
        
        with open('/tmp/kiosk-playlist-index', 'w') as f:
            f.write(str(current_index))
            
        # Get next URL
        next_url = data['urls'][current_index]['url']
        print(f'Navigating to: {next_url}')
        
        # Navigate browser using Chrome DevTools Protocol
        try:
            subprocess.run(['curl', '-s', '-X', 'POST', 
                          'http://localhost:$DEBUG_PORT/json/runtime/evaluate',
                          '-H', 'Content-Type: application/json',
                          '-d', f'{{\"expression\": \"window.location.href = \\'{next_url}\\'\"}}'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except:
            pass
except Exception as e:
    print(f'Error in playlist rotation: {e}')
"
        done
    ) &
    echo \$! > /tmp/kiosk-playlist-rotation.pid
fi

# Wait for browser process
wait \$BROWSER_PID
EOF
    
    chmod +x "$INSTALL_DIR/start_kiosk.sh"
}

create_simple_api() {
    log_info "Creating API server..."
    
    cat > "$INSTALL_DIR/simple_api.py" << 'EOF'
#!/usr/bin/env python3
import os
import sys
import json
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import threading

CONFIG_FILE = "/opt/kiosk/kiosk.json"

def load_config():
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except:
        # If config file is missing, create a new one with generated API key
        import subprocess
        import secrets
        import string
        
        # Generate a proper API key
        api_key = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(32))
        
        default_config = {
            "kiosk": {"url": "http://example.com", "rotation": "normal"},
            "api": {"api_key": api_key, "port": 80},
            "playlist": {"enabled": False, "default_display_time": 30, "urls": []}
        }
        
        # Save the config file
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

class KioskHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging
        
    def do_GET(self):
        if not check_auth(self):
            return
            
        if self.path.startswith('/status'):
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            
            chromium_running = os.system("pgrep -f chromium >/dev/null") == 0
            x_running = os.system("pgrep Xorg >/dev/null") == 0
            
            try:
                with open(CONFIG_FILE, 'r') as f:
                    current_url = f.read().strip()
            except:
                current_url = "http://example.com"
                
            try:
                config = load_config()
                current_rotation = config.get("kiosk", {}).get("rotation", "normal")
            except:
                current_rotation = "normal"
            
            response = {
                "status": "online",
                "chromium_running": chromium_running,
                "x_server_running": x_running,
                "current_url": current_url,
                "current_rotation": current_rotation
            }
            self.wfile.write(json.dumps(response).encode())
            
        elif self.path.startswith('/api-info'):
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            
            response = {
                "message": "Kiosk API Server",
                "endpoints": [
                    "GET /status", 
                    "POST /set-url",
                    "POST /set-rotation", 
                    "POST /restart",
                    "POST /reboot"
                ]
            }
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        if not check_auth(self):
            return
            
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length)
        
        try:
            data = json.loads(post_data.decode())
        except:
            self.send_response(400)
            self.end_headers()
            return
        
        if self.path.startswith('/set-url'):
            # Handle both single URL and multiple URLs with timers
            urls = data.get('urls', [])
            single_url = data.get('url', '').strip()
            
            if single_url and not urls:
                # Single URL mode - display indefinitely
                try:
                    # Update the main config with single URL and playlist disabled
                    config = load_config()
                    config["kiosk"]["url"] = single_url
                    config["playlist"]["enabled"] = False
                    config["playlist"]["urls"] = [{"url": single_url, "display_time": 999999, "title": "Single URL"}]
                    with open(CONFIG_FILE, 'w') as f:
                        json.dump(config, f, indent=2)
                    
                    self.send_response(200)
                    self.send_header('Content-type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({"status": "success", "url": single_url, "mode": "single"}).encode())
                    
                    # Try seamless DevTools navigation first, fallback to restart
                    def navigate_seamlessly():
                        import subprocess
                        try:
                            # Call the same navigation function used by CLI
                            result = subprocess.run(['bash', '-c', f'source /opt/kiosk/kiosk-setup.sh && navigate_browser_to_url "{single_url}"'],
                                                  capture_output=True, text=True, timeout=30)
                            if result.returncode != 0:
                                # DevTools navigation failed, restart as fallback
                                os.system("systemctl restart kiosk.service")
                        except:
                            # Any error, restart as fallback
                            os.system("systemctl restart kiosk.service")
                    threading.Thread(target=navigate_seamlessly, daemon=True).start()
                except:
                    self.send_response(500)
                    self.end_headers()
            
            elif urls and isinstance(urls, list):
                # Multiple URLs mode with timers
                try:
                    processed_urls = []
                    for item in urls:
                        if isinstance(item, dict):
                            url = item.get('url', '').strip()
                            duration = item.get('duration', 30)  # Default 30 seconds
                            title = item.get('title', url.split('//')[-1].split('/')[0] if '//' in url else 'URL')
                            
                            if url:
                                processed_urls.append({
                                    "url": url,
                                    "display_time": int(duration),
                                    "title": title
                                })
                        elif isinstance(item, str):
                            # Simple URL string, use default duration
                            url = item.strip()
                            if url:
                                processed_urls.append({
                                    "url": url,
                                    "display_time": 30,
                                    "title": url.split('//')[-1].split('/')[0] if '//' in url else 'URL'
                                })
                    
                    if processed_urls:
                        # Update main config with playlist
                        config = load_config()
                        config["kiosk"]["url"] = processed_urls[0]['url']  # Set first URL as fallback
                        config["playlist"]["enabled"] = len(processed_urls) > 1
                        config["playlist"]["default_display_time"] = 30
                        config["playlist"]["urls"] = processed_urls
                        
                        with open(CONFIG_FILE, 'w') as f:
                            json.dump(config, f, indent=2)
                        
                        self.send_response(200)
                        self.send_header('Content-type', 'application/json')
                        self.end_headers()
                        
                        response = {
                            "status": "success", 
                            "mode": "playlist" if len(processed_urls) > 1 else "single",
                            "url_count": len(processed_urls),
                            "urls": processed_urls
                        }
                        self.wfile.write(json.dumps(response).encode())
                        
                        # For playlist mode, restart is needed to properly initialize rotation
                        threading.Thread(target=lambda: os.system("systemctl restart kiosk.service"), daemon=True).start()
                    else:
                        self.send_response(400)
                        self.send_header('Content-type', 'application/json')
                        self.end_headers()
                        self.wfile.write(json.dumps({"error": "No valid URLs provided"}).encode())
                except Exception as e:
                    self.send_response(500)
                    self.send_header('Content-type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({"error": str(e)}).encode())
            else:
                self.send_response(400)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Either 'url' or 'urls' field required"}).encode())
                
        elif self.path.startswith('/set-rotation'):
            rotation = data.get('rotation', '').strip().lower()
            valid_rotations = ['normal', 'left', 'right', 'inverted']
            
            if rotation in valid_rotations:
                try:
                    config = load_config()
                    config["kiosk"]["rotation"] = rotation
                    with open(CONFIG_FILE, 'w') as f:
                        json.dump(config, f, indent=2)
                    
                    # Apply rotation immediately
                    os.system(f'DISPLAY=:0 xrandr --output $(DISPLAY=:0 xrandr | grep " connected" | head -1 | cut -d" " -f1) --rotate {rotation} 2>/dev/null || true')
                    
                    self.send_response(200)
                    self.send_header('Content-type', 'application/json')
                    self.end_headers()
                    self.wfile.write(json.dumps({"status": "success", "rotation": rotation}).encode())
                except:
                    self.send_response(500)
                    self.end_headers()
            else:
                self.send_response(400)
                self.end_headers()
                
        elif self.path.startswith('/restart'):
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "restarting"}).encode())
            threading.Thread(target=lambda: os.system("systemctl restart kiosk.service"), daemon=True).start()
            
        elif self.path.startswith('/reboot'):
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "rebooting"}).encode())
            threading.Thread(target=lambda: os.system("reboot"), daemon=True).start()
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    try:
        server = HTTPServer(('0.0.0.0', 80), KioskHandler)
        print("Kiosk API Server running on port 80")
        server.serve_forever()
    except PermissionError:
        print("Permission denied for port 80, trying port 8080...")
        server = HTTPServer(('0.0.0.0', 8080), KioskHandler)
        print("Kiosk API Server running on port 8080")
        server.serve_forever()
EOF
    
    chmod +x "$INSTALL_DIR/simple_api.py"
}

create_systemd_services() {
    log_info "Creating systemd services..."
    
    # Main kiosk service
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
    
    # API service
    cat > "$API_SERVICE_FILE" << EOF
[Unit]
Description=Kiosk API Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/simple_api.py
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5
User=root
Group=root

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
    chmod 644 "$CONFIG_FILE" "$API_CONFIG_FILE" "$ROTATION_CONFIG_FILE" 2>/dev/null || true
    
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
    
    echo
    echo "========================================"
    echo "    KIOSK SETUP COMPLETE!"
    echo "========================================"
    echo "Architecture: $arch_info"
    echo "User '$KIOSK_USER' created"
    echo "Browser: $CHROMIUM_PATH"
    echo "System packages installed"
    echo "Systemd services configured"
    echo "Autologin enabled"
    echo "Screen blanking disabled"
    echo
    echo "FILES CREATED:"
    echo "   Config: $CONFIG_FILE"
    echo "   Usage:  $INSTALL_DIR/USAGE_EXAMPLES.md"
    echo
    echo "API CONFIGURATION:"
    echo "   API Key: $api_key"
    echo
    echo "QUICK START COMMANDS:"
    echo "   kiosk status                    # Check system status"
    echo "   kiosk set-url <URL>             # Set single URL"
    echo "   kiosk playlist-add <URL> [time] # Add to playlist"
    echo "   kiosk playlist-enable           # Enable playlist rotation"
    echo "   kiosk set-rotation <rotation>   # Rotate screen"
    echo "   kiosk get-api-key               # Show API key"
    echo "   kiosk restart                   # Restart services"
    echo
    echo "COMPREHENSIVE EXAMPLES:"
    echo "   All usage examples with API calls, programming"
    echo "   examples, and automation scripts available in:"
    echo "   $INSTALL_DIR/USAGE_EXAMPLES.md"
    echo
    local ip_addr=$(hostname -I | awk '{print $1}' 2>/dev/null || echo '<this-ip>')
    echo "API ENDPOINTS (after reboot):"
    echo "   GET  http://$ip_addr/status?api_key=$api_key"
    echo "   POST http://$ip_addr/set-url?api_key=$api_key"
    echo "   POST http://$ip_addr/set-rotation?api_key=$api_key"
    echo "   POST http://$ip_addr/restart?api_key=$api_key"
    echo "   POST http://$ip_addr/reboot?api_key=$api_key"
    echo
    echo "NEXT STEPS:"
    echo "   1. sudo reboot"
    echo "   2. System will auto-login as '$KIOSK_USER'"
    echo "   3. Kiosk will start automatically"
    echo "   4. View examples: cat $INSTALL_DIR/USAGE_EXAMPLES.md"
    echo "   5. Manage with: kiosk <command>"
    echo "========================================"
}

# ==========================================
# MANAGEMENT FUNCTIONS
# ==========================================

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
        exit 1
    fi
    
    # Validate URL format and security
    if ! validate_url "$url"; then
        log_error "Invalid or unsafe URL provided"
        exit 1
    fi
    
    # Set new URL and disable playlist mode
    set_config_value "kiosk.url" "$url"
    set_config_value "playlist.enabled" "false"
    
    
    log_info "URL set to: $url"
    
    # Try to navigate without restarting (seamless)
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
    get_config_value "kiosk.rotation" "normal"
}

set_rotation() {
    local rotation="$1"
    
    if [[ -z "$rotation" ]]; then
        log_error "Rotation is required"
        echo "Usage: kiosk set-rotation <normal|left|right|inverted>"
        exit 1
    fi
    
    # Validate rotation input
    if ! validate_rotation "$rotation"; then
        log_error "Invalid rotation value provided"
        exit 1
    fi
    
    # Normalize rotation (convert to lowercase)
    rotation=$(echo "$rotation" | tr '[:upper:]' '[:lower:]')
    
    # Backup current configuration
    backup_config
    
    # Save rotation to unified config
    set_config_value "kiosk.rotation" "$rotation"
    
    log_info "Rotation set to: $rotation"
    
    # Apply rotation immediately if X server is running
    if pgrep Xorg > /dev/null; then
        log_info "Applying rotation immediately..."
        export DISPLAY=:0
        
        # Get primary display with error handling
        local primary_display
        primary_display=$(timeout 5 xrandr --query 2>/dev/null | grep " connected" | head -1 | cut -d' ' -f1)
        
        if [[ -n "$primary_display" ]]; then
            log_debug "Applying rotation to display: $primary_display"
            if ! retry_command 2 2 "xrandr --output '$primary_display' --rotate '$rotation'"; then
                log_warn "Failed to apply rotation immediately, will be applied on next startup"
                # Don't exit - rotation is saved and will be applied on restart
            else
                log_info "Rotation applied successfully to display: $primary_display"
            fi
        else
            log_warn "Could not detect primary display, rotation will be applied on startup"
        fi
    else
        log_info "X server not running, rotation will be applied on startup"
    fi
}

get_api_key() {
    get_config_value "api.api_key" "default-key"
}

regenerate_api_key() {
    check_root "regenerate-api-key"
    
    local new_key
    new_key=$(generate_api_key)
    
    # Update unified configuration file
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
    
    # Architecture info
    local arch_info="$ARCH"
    [[ "$IS_RPI" == true ]] && arch_info="$arch_info (Raspberry Pi)"
    echo "Architecture:     $arch_info"
    echo "Timestamp:        $(date)"
    echo
    
    # Services with enhanced status
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
    
    # Processes with memory info
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
    
    # Configuration with validation
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
    
    # Network info
    local ip_addr
    ip_addr=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    echo "IP Address:       ${ip_addr:-"Unknown"}"
    
    echo "========================================"
    
    # Overall health status
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
    echo "  kiosk get-rotation               - Get current screen rotation"
    echo "  kiosk set-rotation <rotation>    - Set screen rotation (normal|left|right|inverted)"
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
    echo "  kiosk set-url http://google.com"
    echo "  kiosk set-rotation left"
    echo "  kiosk logs kiosk"
    echo
    echo "API USAGE:"
    echo "  curl \"http://<ip>/status?api_key=<key>\""
    echo "  curl -X POST \"http://<ip>/set-url?api_key=<key>\" -H \"Content-Type: application/json\" -d '{\"url\":\"http://google.com\"}'"
}

# ==========================================
# MAIN SETUP FUNCTION
# ==========================================

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

# ==========================================
# MAIN COMMAND HANDLER
# ==========================================

main() {
    # Check for one-line install mode (when no arguments and piped from curl)
    if [[ -z "${1:-}" && "$0" =~ /dev/fd/ ]]; then
        log_info "One-line installer detected"
        if [[ $EUID -eq 0 ]]; then
            log_info "Running as root, proceeding with setup..."
            
            # Save script to disk for future management
            log_info "Saving kiosk-setup.sh script for future use..."
            mkdir -p /opt/kiosk
            curl -s https://raw.githubusercontent.com/zitlem/Kiosk-URL/master/kiosk-setup.sh -o /opt/kiosk/kiosk-setup.sh 2>/dev/null || {
                log_warn "Could not download script for saving, copying current script..."
                # Fallback: copy the current running script
                cp "$0" /opt/kiosk/kiosk-setup.sh 2>/dev/null || true
            }
            
            chmod +x /opt/kiosk/kiosk-setup.sh 2>/dev/null || true
            
            # Create convenient symlink
            ln -sf /opt/kiosk/kiosk-setup.sh /usr/local/bin/kiosk 2>/dev/null || true
            
            log_info "Running setup..."
            run_setup
            
            echo
            echo "============================================"
            echo "    KIOSK INSTALLATION COMPLETE!"
            echo "============================================"
            echo "The script has been saved to: /opt/kiosk/kiosk-setup.sh"
            echo "A convenient command has been created: kiosk"
            echo
            echo "USAGE EXAMPLES AVAILABLE:"
            echo "  cat /opt/kiosk/USAGE_EXAMPLES.md"
            echo
            echo "After reboot, you can manage with:"
            echo "  kiosk status"
            echo "  kiosk set-url http://google.com"
            echo "  kiosk playlist-add http://site.com 60"
            echo "  kiosk help"
            echo
            echo "API will be available at: http://$(hostname -I | awk '{print $1}' 2>/dev/null || echo '<this-ip>')"
            
            local api_key
            api_key=$(get_api_key 2>/dev/null || echo "check-after-reboot")
            echo "API Key: $api_key"
            echo "============================================"
            echo
            
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
            echo "  ✅ Set up automatic browser rotation with URL playlist"
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
    
    # Enable error handling for all operations
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
        "set-rotation")
            set_rotation "$2"
            ;;
        "get-api-key")
            get_api_key
            ;;
        "regenerate-api-key")
            regenerate_api_key
            ;;
        "test-devtools")
            echo "Testing DevTools connectivity on port $DEBUG_PORT..."
            if curl -s --connect-timeout 5 "http://localhost:$DEBUG_PORT/json" | python3 -c "import json,sys; tabs=json.load(sys.stdin); print(f'Found {len(tabs)} tabs'); [print(f'Tab {i}: {t.get(\"title\",\"No title\")} - {t.get(\"url\",\"No URL\")}') for i,t in enumerate(tabs)]" 2>/dev/null; then
                echo "DevTools is accessible and working"
            else
                echo "DevTools is not accessible on port $DEBUG_PORT"
                echo "Check if Chrome is running with --remote-debugging-port=$DEBUG_PORT"
            fi
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
        # Configuration management
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
            
            if ! validate_config_file "$ROTATION_CONFIG_FILE" "rotation"; then
                ((errors++))
            fi
            
            if ! validate_config_file "$API_CONFIG_FILE" "api"; then
                ((errors++))
            fi
            
            if ! validate_config_file "$PLAYLIST_CONFIG_FILE" "playlist"; then
                ((errors++))
            fi
            
            if [[ $errors -eq 0 ]]; then
                log_info "All configurations are valid"
            else
                log_error "Found $errors configuration errors"
                exit 1
            fi
            ;;
        # Playlist management
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
            # Alias for playlist-replace for clarity
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
            log_info "Restarting kiosk service to enable playlist..."
            systemctl restart kiosk.service 2>/dev/null || log_warn "Could not restart service automatically"
            ;;
        "playlist-disable")
            disable_playlist
            log_info "Restarting kiosk service to disable playlist..."
            systemctl restart kiosk.service 2>/dev/null || log_warn "Could not restart service automatically"
            ;;
        "playlist-clear")
            check_root "playlist-clear"
            backup_config
            create_default_playlist
            log_info "Playlist cleared to default state"
            ;;
        # Debug and maintenance
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
        # Enhanced help and information
        "version")
            echo "Universal Kiosk Management System"
            echo "Architecture: $ARCH"
            [[ "$IS_ARM" == true ]] && echo "ARM optimizations: Enabled"
            [[ "$IS_RPI" == true ]] && echo "Raspberry Pi optimizations: Enabled"
            echo "Browser path: ${CHROMIUM_PATH:-"Not detected"}"
            
            # Detect browser installation method
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

# Run main function with all arguments
main "$@"