import os
import subprocess
import sys
import time
import requests
import json
import logging
import secrets
import argparse
from flask import Flask, request, jsonify
from urllib.parse import urlparse
from functools import wraps

app = Flask(__name__)

# Configure logging with fallback for permission issues
def setup_logging():
    """Setup logging with permission-aware file handling"""
    handlers = []
    
    # Always add console handler
    handlers.append(logging.StreamHandler())
    
    # Try to add file handler, fallback if no permissions
    log_file = '/opt/kiosk/kiosk.log'
    try:
        # Test if we can write to the log file
        with open(log_file, 'a') as f:
            pass
        handlers.append(logging.FileHandler(log_file))
    except (PermissionError, FileNotFoundError):
        # Fallback to user-writable location or skip file logging
        try:
            fallback_log = f'/tmp/kiosk_{os.getuid()}.log'
            handlers.append(logging.FileHandler(fallback_log))
            print(f"Warning: Using fallback log file: {fallback_log}")
        except Exception:
            print("Warning: File logging disabled due to permission issues")
    
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=handlers,
        force=True
    )
    
    return logging.getLogger(__name__)

logger = setup_logging()

CONFIG_FILE = "/opt/kiosk/kiosk_url.txt"
API_CONFIG_FILE = "/opt/kiosk/api_config.json"
DEBUG_PORT = 9222
SERVICE_FILE = "/etc/systemd/system/kiosk.service"
SETUP_MARKER = "/opt/kiosk/.setup_complete"
ROTATION_CONFIG_FILE = "/opt/kiosk/rotation_config.txt"
KIOSK_USER = "kiosk"

SYSTEM_PACKAGES = [
    "xserver-xorg", "x11-xserver-utils", "xinit",
    "openbox", "unclutter",
    "chromium", "chromium-common", "chromium-sandbox", "python3-xdg"
]

PYTHON_PACKAGES = ["flask", "requests", "websocket-client"]

CHROMIUM_PATH = "/usr/bin/chromium"  # Will detect later


def run_cmd(cmd, timeout=30):
    """Run a command with timeout and proper error handling"""
    try:
        result = subprocess.run(
            cmd, 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE, 
            text=True,
            timeout=timeout,
            check=False
        )
        return (result.returncode == 0, result.stdout.strip(), result.stderr.strip())
    except subprocess.TimeoutExpired:
        logger.error(f"Command timed out: {' '.join(cmd)}")
        return (False, "", "Command timed out")
    except Exception as e:
        logger.error(f"Error running {' '.join(cmd)}: {e}")
        return (False, "", str(e))


def ensure_directory_exists(path):
    """Ensure directory exists with proper permissions"""
    os.makedirs(path, exist_ok=True)


def create_kiosk_user():
    """Create kiosk user if it doesn't exist - simplified for compatibility"""
    logger.info(f"Checking for user '{KIOSK_USER}'...")
    
    # Check if user exists
    ok, stdout, stderr = run_cmd(["id", KIOSK_USER])
    if ok:
        logger.info(f"User '{KIOSK_USER}' already exists")
        return True
    
    logger.info(f"Creating user '{KIOSK_USER}'...")
    try:
        # Create user with home directory - compatible with all Debian systems
        subprocess.run([
            "useradd", "-m", "-s", "/bin/bash", 
            "-G", "audio,video,users", KIOSK_USER
        ], check=True, timeout=30)
        
        # Set up basic home directory structure
        home_dir = f"/home/{KIOSK_USER}"
        subprocess.run(["mkdir", "-p", f"{home_dir}/.config"], check=True)
        subprocess.run(["chown", "-R", f"{KIOSK_USER}:{KIOSK_USER}", home_dir], check=True)
        
        logger.info(f"User '{KIOSK_USER}' created successfully")
        return True
        
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to create user '{KIOSK_USER}': {e}")
        logger.info("Note: Running as root for system compatibility")
        return True  # Continue anyway, we'll run as root
    except Exception as e:
        logger.error(f"Error creating user: {e}")
        return True  # Continue anyway, we'll run as root


def generate_api_key():
    """Generate a secure API key"""
    return secrets.token_urlsafe(32)


def load_api_config():
    """Load API configuration with permission handling"""
    default_config = {
        "api_key": generate_api_key(),
        "require_auth": True
    }
    
    try:
        if os.path.exists(API_CONFIG_FILE):
            with open(API_CONFIG_FILE, "r") as f:
                config = json.load(f)
                # Ensure all required keys exist
                for key, value in default_config.items():
                    if key not in config:
                        config[key] = value
                return config
        else:
            # Create new config
            save_api_config(default_config)
            return default_config
            
    except PermissionError:
        logger.warning(f"Cannot access API config file {API_CONFIG_FILE}, using defaults")
        return default_config
    except Exception as e:
        logger.error(f"Error loading API config: {e}")
        return default_config


def save_api_config(config):
    """Save API configuration with permission handling"""
    try:
        ensure_directory_exists(os.path.dirname(API_CONFIG_FILE))
        with open(API_CONFIG_FILE, "w") as f:
            json.dump(config, f, indent=2)
        
        # Set proper permissions (only if we have permission to do so)
        try:
            current_user = os.getenv("USER", "root")
            if current_user == KIOSK_USER or os.getuid() != 0:
                # Running as kiosk user, set appropriate permissions
                os.chmod(API_CONFIG_FILE, 0o644)
            else:
                # Running as root, set kiosk user ownership
                subprocess.run(["chown", f"{KIOSK_USER}:{KIOSK_USER}", API_CONFIG_FILE], 
                              stderr=subprocess.DEVNULL, check=False)
                os.chmod(API_CONFIG_FILE, 0o644)
        except (PermissionError, FileNotFoundError):
            logger.warning("Could not set file permissions on API config")
        
        logger.info("API configuration saved")
        
    except PermissionError:
        logger.error(f"Permission denied saving API config to {API_CONFIG_FILE}")
        raise
    except Exception as e:
        logger.error(f"Error saving API config: {e}")
        raise


def require_api_key(f):
    """Decorator to require API key authentication"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        config = load_api_config()
        
        if not config.get("require_auth", True):
            return f(*args, **kwargs)
        
        # Check for API key in headers
        api_key = request.headers.get('X-API-Key')
        if not api_key:
            # Check for API key in query parameters (less secure, but convenient)
            api_key = request.args.get('api_key')
        
        if not api_key or api_key != config.get("api_key"):
            return jsonify({"error": "Invalid or missing API key"}), 401
        
        return f(*args, **kwargs)
    
    return decorated_function


def regenerate_api_key():
    """Regenerate API key"""
    config = load_api_config()
    config["api_key"] = generate_api_key()
    save_api_config(config)
    logger.info("API key regenerated")
    return config["api_key"]


def create_sudoers_entries():
    """Create sudoers entries for kiosk user to run specific commands as root"""
    sudoers_content = f"""# Kiosk user permissions
{KIOSK_USER} ALL=(root) NOPASSWD: /usr/sbin/reboot
{KIOSK_USER} ALL=(root) NOPASSWD: /usr/sbin/shutdown
{KIOSK_USER} ALL=(root) NOPASSWD: /bin/systemctl restart kiosk.service
"""
    
    try:
        # Write to a temporary file first
        with open("/tmp/kiosk-sudoers", "w") as f:
            f.write(sudoers_content)
        
        # Validate the sudoers file
        result = subprocess.run(["visudo", "-c", "-f", "/tmp/kiosk-sudoers"], 
                               capture_output=True, text=True)
        if result.returncode == 0:
            # Copy to sudoers.d
            subprocess.run(["cp", "/tmp/kiosk-sudoers", "/etc/sudoers.d/kiosk"], check=True)
            subprocess.run(["chmod", "440", "/etc/sudoers.d/kiosk"], check=True)
            logger.info("Sudoers entries created for kiosk user")
        else:
            logger.error(f"Invalid sudoers syntax: {result.stderr}")
            
        # Clean up temp file
        subprocess.run(["rm", "-f", "/tmp/kiosk-sudoers"], check=False)
        
    except Exception as e:
        logger.error(f"Failed to create sudoers entries: {e}")


def ensure_system_packages():
    """Install system packages with better error handling and dependency resolution"""
    logger.info("Checking system packages...")
    try:
        # Update package lists
        subprocess.run(["apt-get", "update"], check=True, timeout=300)
        
        # Fix any broken packages first
        subprocess.run(["apt-get", "install", "-f", "-y"], check=True, timeout=300)
        
        # Handle problematic packages that might conflict
        logger.info("Resolving potential package conflicts...")
        
        # Remove conflicting packages if they exist
        conflicting_packages = ["luit"]
        for pkg in conflicting_packages:
            ok, stdout, stderr = run_cmd(["dpkg", "-s", pkg])
            if ok:
                logger.info(f"Removing potentially conflicting package: {pkg}")
                subprocess.run(["apt-get", "remove", "-y", pkg], 
                             stderr=subprocess.DEVNULL, check=False)
        
        # Install packages in specific order to avoid conflicts
        essential_packages = [
            "xserver-xorg-core",  # Core X server
            "xserver-xorg",       # Full X server
            "x11-xserver-utils",  # X server utilities
            "xinit",              # X init
            "openbox",            # Window manager
            "unclutter",          # Hide cursor
        ]
        
        for pkg in essential_packages:
            ok, stdout, stderr = run_cmd(["dpkg", "-s", pkg])
            if not ok:
                logger.info(f"Installing {pkg}...")
                try:
                    subprocess.run(
                        ["apt-get", "install", "-y", "--no-install-recommends", pkg], 
                        check=True, 
                        timeout=300
                    )
                except subprocess.CalledProcessError as e:
                    logger.warning(f"Failed to install {pkg}, trying alternative approach: {e}")
                    # Try without recommends and with force
                    subprocess.run([
                        "apt-get", "install", "-y", "--no-install-recommends", 
                        "--fix-missing", pkg
                    ], check=False, timeout=300)

        # Install Chromium separately with specific handling
        logger.info("Installing Chromium...")
        chromium_installed = False
        chromium_packages = [
            ["chromium-browser"],  # Try browser version first
            ["chromium"],          # Fallback to regular chromium
            ["chromium-common", "chromium-sandbox", "chromium"],  # Individual components
        ]
        
        for pkg_list in chromium_packages:
            try:
                logger.info(f"Attempting to install: {' '.join(pkg_list)}")
                subprocess.run([
                    "apt-get", "install", "-y", "--no-install-recommends"
                ] + pkg_list, check=True, timeout=300)
                chromium_installed = True
                break
            except subprocess.CalledProcessError as e:
                logger.warning(f"Failed to install {' '.join(pkg_list)}: {e}")
                continue
        
        if not chromium_installed:
            logger.error("Failed to install Chromium through apt. Trying snap...")
            try:
                subprocess.run(["snap", "install", "chromium"], check=True, timeout=300)
                chromium_installed = True
            except subprocess.CalledProcessError:
                logger.error("Failed to install Chromium via snap as well")
        
        # Final cleanup
        subprocess.run(["apt-get", "autoremove", "-y"], check=False, timeout=120)
        subprocess.run(["apt-get", "autoclean"], check=False, timeout=120)
        
        logger.info("System packages installation completed")
        
    except subprocess.CalledProcessError as e:
        logger.error(f"Package installation failed: {e}")
        raise
    except subprocess.TimeoutExpired:
        logger.error("Package installation timed out")
        raise


def ensure_python_packages():
    """Install Python packages with better error handling"""
    logger.info("Checking Python packages...")
    import importlib
    
    for pkg in PYTHON_PACKAGES:
        module = pkg if pkg != "websocket-client" else "websocket"
        try:
            importlib.import_module(module)
            logger.info(f"Package {pkg} already installed")
        except ImportError:
            logger.info(f"Installing Python package: {pkg}")
            try:
                subprocess.run([
                    sys.executable, "-m", "pip", "install", 
                    "--break-system-packages", pkg
                ], check=True, timeout=300)
            except subprocess.CalledProcessError as e:
                logger.error(f"Failed to install {pkg}: {e}")
                raise


def create_systemd_service(user=KIOSK_USER):
    """Create systemd service that runs as root for port 80 access"""
    if os.path.exists(SERVICE_FILE):
        logger.info("systemd service already exists.")
        return

    logger.info("Creating systemd service...")
    # Create a wrapper script that starts X as root
    wrapper_script = "/opt/kiosk/start_kiosk.sh"
    wrapper_content = f"""#!/bin/bash
set -e

# Start X server as root if not running
if ! pgrep Xorg >/dev/null; then
    echo "Starting X server as root..."
    X :0 -nolisten tcp -noreset +extension GLX vt1 &
    sleep 3
    
    # Set permissions for kiosk user
    xhost +local: 2>/dev/null || true
    xhost +local:{user} 2>/dev/null || true
    chown {user}:{user} /tmp/.X11-unix/X0 2>/dev/null || true
    chmod 666 /tmp/.X11-unix/X0 2>/dev/null || true
fi

# Run the kiosk API as root to access port 80
export DISPLAY=:0
export HOME=/opt/kiosk
cd /opt/kiosk
exec python3 /opt/kiosk/kiosk_api.py
"""

    try:
        # Write wrapper script
        with open(wrapper_script, "w") as f:
            f.write(wrapper_content)
        subprocess.run(["chmod", "+x", wrapper_script], check=True)

        # Write systemd service - run as root for port 80 and reboot access
        service_content = f"""[Unit]
Description=Kiosk Web API
After=graphical.target
Wants=graphical.target

[Service]
Type=simple
ExecStart={wrapper_script}
WorkingDirectory=/opt/kiosk
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
"""

        with open("/tmp/kiosk.service", "w") as f:
            f.write(service_content)

        subprocess.run(["mv", "/tmp/kiosk.service", SERVICE_FILE], check=True)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", "kiosk.service"], check=True)
        logger.info("Service created and enabled.")

    except Exception as e:
        logger.error(f"Failed to create systemd service: {e}")
        raise


def setup_kiosk_permissions():
    """Set up proper permissions for kiosk files - everything owned by root"""
    try:
        # Ensure kiosk directory exists
        ensure_directory_exists("/opt/kiosk")
        
        # Set up proper ownership - root owns everything for consistency
        subprocess.run(["chown", "-R", "root:root", "/opt/kiosk"], check=True)
        subprocess.run(["chmod", "755", "/opt/kiosk"], check=True)
        
        # Make scripts executable
        subprocess.run(["chmod", "+x", "/opt/kiosk/kiosk_api.py"], check=True)
        if os.path.exists("/opt/kiosk/start_kiosk.sh"):
            subprocess.run(["chmod", "+x", "/opt/kiosk/start_kiosk.sh"], check=True)
        if os.path.exists("/opt/kiosk/disable_blanking.sh"):
            subprocess.run(["chmod", "+x", "/opt/kiosk/disable_blanking.sh"], check=True)
        
        # Ensure config files exist and have proper ownership
        for config_file in [CONFIG_FILE, API_CONFIG_FILE, ROTATION_CONFIG_FILE]:
            # Create file if it doesn't exist
            if not os.path.exists(config_file):
                subprocess.run(["touch", config_file], check=True)
            # Set proper ownership and permissions
            subprocess.run(["chown", "root:root", config_file], check=True)
            subprocess.run(["chmod", "644", config_file], check=True)
        
        logger.info("Kiosk permissions set up - all files owned by root")
        
    except Exception as e:
        logger.error(f"Failed to setup permissions: {e}")
        raisee


def disable_screen_blanking():
    """Disable screen blanking and power management"""
    try:
        # Create xorg.conf.d directory if it doesn't exist
        xorg_dir = "/etc/X11/xorg.conf.d"
        ensure_directory_exists(xorg_dir)
        
        # Create screen blanking disable config
        screen_config = f"""{xorg_dir}/10-screen.conf"""
        screen_content = """Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "Extensions"
    Option "DPMS" "Disable"
EndSection
"""
        
        with open(screen_config, "w") as f:
            f.write(screen_content)
        
        logger.info("Screen blanking disabled in X configuration")
        
        # Also create a script to disable it at runtime
        disable_script = "/opt/kiosk/disable_blanking.sh"
        disable_content = """#!/bin/bash
export DISPLAY=:0
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
xset s noblank 2>/dev/null || true
"""
        
        with open(disable_script, "w") as f:
            f.write(disable_content)
        subprocess.run(["chmod", "+x", disable_script], check=True)
        
        logger.info("Runtime screen blanking disable script created")
        
    except Exception as e:
        logger.error(f"Failed to disable screen blanking: {e}")


def start_gui_if_needed():
    """Start GUI components and apply saved rotation - assumes X server is already running from wrapper"""
    # Use real display :0
    if not os.getenv("DISPLAY"):
        os.environ["DISPLAY"] = ":0"

    current_user = os.getenv("USER", "unknown")
    current_uid = os.getuid()
    logger.info(f"Starting GUI as user: {current_user} (UID: {current_uid})")

    # Disable screen blanking
    try:
        subprocess.run(["/opt/kiosk/disable_blanking.sh"], 
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        logger.info("Screen blanking disabled")
    except Exception as e:
        logger.warning(f"Failed to disable screen blanking: {e}")

    # Verify X is accessible
    try:
        result = subprocess.run([
            "xdpyinfo", "-display", ":0"
        ], capture_output=True, timeout=5)
        if result.returncode != 0:
            logger.error("X server is not accessible")
            logger.error(f"xdpyinfo error: {result.stderr.decode()}")
            return False
        else:
            logger.info("X server is accessible and ready")
    except Exception as e:
        logger.error(f"Cannot verify X server accessibility: {e}")
        return False

    # Apply saved rotation BEFORE starting other GUI components
    try:
        apply_saved_rotation()
    except Exception as e:
        logger.warning(f"Failed to apply saved rotation: {e}")

    # Check if openbox is running
    ok, stdout, stderr = run_cmd(["pgrep", "openbox"])
    if not ok:
        logger.info("Starting Openbox...")
        try:
            subprocess.Popen(
                ["openbox"], 
                env=dict(os.environ, DISPLAY=":0"),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            time.sleep(3)
            logger.info("Openbox started")
        except Exception as e:
            logger.error(f"Failed to start Openbox: {e}")

    # Start unclutter to hide cursor
    ok, stdout, stderr = run_cmd(["pgrep", "unclutter"])
    if not ok:
        logger.info("Starting unclutter to hide cursor...")
        try:
            subprocess.Popen([
                "unclutter", 
                "-display", ":0", 
                "-noevents", 
                "-grab",
                "-idle", "1"
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
            )
            time.sleep(2)
            logger.info("Unclutter started - cursor should be hidden")
        except Exception as e:
            logger.warning(f"Failed to start unclutter: {e}")
            # Try alternative cursor hiding method
            try:
                subprocess.run([
                    "xsetroot", "-cursor_name", "none"
                ],
                env=dict(os.environ, DISPLAY=":0"),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5
                )
                logger.info("Alternative cursor hiding method applied")
            except Exception as e2:
                logger.warning(f"Alternative cursor hiding also failed: {e2}")

    # Set black background
    try:
        subprocess.run([
            "xsetroot", "-solid", "black"
        ],
        env=dict(os.environ, DISPLAY=":0"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=5
        )
        logger.info("Set black background")
    except Exception as e:
        logger.warning(f"Failed to set background: {e}")

    return True


def set_screen_rotation(rotation):
    """Set screen rotation using xrandr and save setting"""
    valid_rotations = ["normal", "left", "right", "inverted"]
    
    if rotation not in valid_rotations:
        raise ValueError(f"Invalid rotation. Must be one of: {valid_rotations}")
    
    try:
        # Get the primary display name
        result = subprocess.run([
            "xrandr", "--query"
        ], capture_output=True, text=True, timeout=10)
        
        if result.returncode != 0:
            raise Exception("Failed to query displays")
        
        # Parse xrandr output to find primary display
        primary_display = None
        for line in result.stdout.split('\n'):
            if " connected primary " in line or " connected " in line:
                primary_display = line.split()[0]
                break
        
        if not primary_display:
            # Fallback to common display names
            for display_name in ["HDMI-1", "VGA-1", "eDP-1", "DP-1", "DVI-1"]:
                test_result = subprocess.run([
                    "xrandr", "--output", display_name, "--query"
                ], capture_output=True, timeout=5)
                if test_result.returncode == 0:
                    primary_display = display_name
                    break
        
        if not primary_display:
            raise Exception("Could not detect primary display")
        
        # Apply rotation
        subprocess.run([
            "xrandr", "--output", primary_display, "--rotate", rotation
        ], check=True, timeout=10, env=dict(os.environ, DISPLAY=":0"))
        
        # Save the rotation setting for persistence
        save_rotation_setting(rotation)
        
        logger.info(f"Screen rotation set to: {rotation} on display: {primary_display}")
        return primary_display
        
    except subprocess.TimeoutExpired:
        raise Exception("Screen rotation command timed out")
    except subprocess.CalledProcessError as e:
        raise Exception(f"Failed to set screen rotation: {e}")
    except Exception as e:
        raise Exception(f"Screen rotation error: {e}")


def get_saved_rotation():
    """Get saved rotation setting with error handling"""
    try:
        if os.path.exists(ROTATION_CONFIG_FILE):
            with open(ROTATION_CONFIG_FILE, "r") as f:
                rotation = f.read().strip()
                valid_rotations = ["normal", "left", "right", "inverted"]
                if rotation in valid_rotations:
                    return rotation
                else:
                    logger.warning(f"Invalid rotation in config file: {rotation}")
    except Exception as e:
        logger.error(f"Error reading rotation config: {e}")
    
    return "normal"  # Default


def save_rotation_setting(rotation):
    """Save rotation setting to config file - persists across reboots"""
    valid_rotations = ["normal", "left", "right", "inverted"]
    
    if rotation not in valid_rotations:
        raise ValueError(f"Invalid rotation. Must be one of: {valid_rotations}")
    
    try:
        ensure_directory_exists(os.path.dirname(ROTATION_CONFIG_FILE))
        with open(ROTATION_CONFIG_FILE, "w") as f:
            f.write(rotation)
        
        # Set proper permissions - readable by all since we're running as root
        os.chmod(ROTATION_CONFIG_FILE, 0o644)

        logger.info(f"Rotation setting saved: {rotation} (persisted to config file)")
    except Exception as e:
        logger.error(f"Error writing rotation config: {e}")
        raise


def apply_saved_rotation():
    """Apply saved rotation setting at startup"""
    try:
        saved_rotation = get_saved_rotation()
        if saved_rotation != "normal":
            logger.info(f"Applying saved rotation: {saved_rotation}")
            set_screen_rotation(saved_rotation)
        else:
            logger.info("Using default rotation: normal")
    except Exception as e:
        logger.error(f"Failed to apply saved rotation: {e}")



def get_screen_rotation():
    """Get current screen rotation, checking both current state and saved setting"""
    try:
        result = subprocess.run([
            "xrandr", "--query"
        ], capture_output=True, text=True, timeout=10, 
        env=dict(os.environ, DISPLAY=":0"))
        
        if result.returncode != 0:
            # If xrandr fails, return saved setting
            return get_saved_rotation()
        
        # Parse xrandr output to find rotation
        for line in result.stdout.split('\n'):
            if " connected " in line and "(" in line:
                # Look for rotation info in parentheses
                if "left" in line:
                    return "left"
                elif "right" in line:
                    return "right" 
                elif "inverted" in line:
                    return "inverted"
                else:
                    return "normal"
        
        # If we can't detect from xrandr, return saved setting
        saved = get_saved_rotation()
        logger.info(f"Could not detect current rotation, using saved: {saved}")
        return saved
        
    except Exception as e:
        logger.error(f"Error getting screen rotation: {e}")
        # Fallback to saved setting
        return get_saved_rotation()


def is_valid_url(url):
    """Validate URL for security"""
    try:
        parsed = urlparse(url)
        return parsed.scheme in ['http', 'https'] and parsed.netloc
    except:
        return False


def get_url():
    """Get current URL with error handling"""
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, "r") as f:
                url = f.read().strip()
                if is_valid_url(url):
                    return url
                else:
                    logger.warning(f"Invalid URL in config file: {url}")
    except Exception as e:
        logger.error(f"Error reading URL config: {e}")
    
    return "http://example.com"


def set_url(url):
    """Set URL with validation and error handling - persists across reboots"""
    if not is_valid_url(url):
        raise ValueError("Invalid URL format")
    
    try:
        ensure_directory_exists(os.path.dirname(CONFIG_FILE))
        with open(CONFIG_FILE, "w") as f:
            f.write(url)
        
        # Set proper permissions - readable by all since we're running as root
        os.chmod(CONFIG_FILE, 0o644)

        logger.info(f"URL set to: {url} (persisted to config file)")
    except Exception as e:
        logger.error(f"Error writing URL config: {e}")
        raise


def kill_existing_chromium():
    """Kill existing Chromium processes"""
    try:
        subprocess.run(["pkill", "-f", "chromium"], stderr=subprocess.DEVNULL, timeout=10)
        time.sleep(2)  # Give processes time to terminate
    except subprocess.TimeoutExpired:
        logger.warning("Timeout killing Chromium processes")
        # Force kill if needed
        subprocess.run(["pkill", "-9", "-f", "chromium"], stderr=subprocess.DEVNULL)


def start_browser(url):
    """Start browser with better error handling and display verification"""
    if not is_valid_url(url):
        logger.error(f"Invalid URL: {url}")
        return False
    
    logger.info(f"Starting browser with URL: {url}")
    
    # Ensure DISPLAY is set
    if not os.getenv("DISPLAY"):
        os.environ["DISPLAY"] = ":0"
    
    # Kill any existing Chromium processes
    kill_existing_chromium()
    
    # Wait for X to be fully ready
    logger.info("Verifying X server is ready...")
    for attempt in range(10):
        try:
            # Test if X is responding
            result = subprocess.run([
                "xdpyinfo", "-display", ":0"
            ], capture_output=True, timeout=3)
            if result.returncode == 0:
                logger.info("X server is responding")
                break
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        time.sleep(1)
    else:
        logger.warning("X server may not be fully ready, proceeding anyway")
    
    try:
        # Enhanced Chromium flags for kiosk mode
        chromium_args = [
            CHROMIUM_PATH,
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-default-apps",
            "--disable-popup-blocking",
            "--disable-translate",
            "--disable-background-timer-throttling",
            "--disable-renderer-backgrounding",
            "--disable-device-discovery-notifications",
            "--disable-infobars",
            "--disable-session-crashed-bubble",
            "--disable-restore-session-state",
            "--noerrdialogs",
            "--kiosk",
            "--start-maximized",
            "--disable-gpu",
            "--disable-software-rasterizer",
            "--disable-web-security",  # Only for kiosk mode
            "--disable-features=TranslateUI,VizDisplayCompositor",
            "--disable-ipc-flooding-protection",
            "--no-sandbox",  # Required when running as root
            "--disable-setuid-sandbox",
            "--force-device-scale-factor=1",
            "--display=:0",  # Explicitly set display
            f"--remote-debugging-port={DEBUG_PORT}",
            "--user-data-dir=/tmp/chromium-kiosk",
            url
        ]
        
        logger.info("Launching Chromium...")
        process = subprocess.Popen(
            chromium_args,
            env=dict(os.environ, 
                    DISPLAY=":0",
                    XDG_RUNTIME_DIR=f"/run/user/{os.getuid()}",
                    HOME="/opt/kiosk"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            preexec_fn=os.setsid  # Create new process group
        )
        
        # Give Chromium time to start
        time.sleep(5)
        
        # Check if process is still running
        if process.poll() is None:
            logger.info("Chromium process started successfully")
            
            # Verify Chromium is actually displaying
            time.sleep(3)
            ok, _, _ = run_cmd(["pgrep", "-f", "chromium"])
            if ok:
                logger.info("Chromium is running and should be visible on display")
                
                # Additional cursor hiding after browser starts
                try:
                    subprocess.Popen([
                        "unclutter", "-display", ":0", "-idle", "1", "-root"
                    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except:
                    pass
                
                return True
            else:
                logger.error("Chromium process disappeared after startup")
                return False
        else:
            stderr_output = process.stderr.read().decode() if process.stderr else ""
            logger.error(f"Chromium failed to start: {stderr_output}")
            return False
            
    except Exception as e:
        logger.error(f"Error starting browser: {e}")
        return False


def navigate_browser(url):
    """Navigate browser using Chrome DevTools Protocol"""
    if not is_valid_url(url):
        logger.error(f"Invalid URL for navigation: {url}")
        return False
    
    try:
        # Wait for debug port to be available
        for attempt in range(10):
            try:
                response = requests.get(f"http://localhost:{DEBUG_PORT}/json", timeout=2)
                if response.status_code == 200:
                    break
            except requests.RequestException:
                time.sleep(1)
        else:
            logger.error("Chrome debugging port not available")
            return False
        
        tabs = response.json()
        if not tabs:
            logger.error("No Chrome tabs found")
            return False
            
        ws_url = tabs[0]["webSocketDebuggerUrl"]
        
        import websocket
        ws = websocket.create_connection(ws_url, timeout=5)
        
        # Proper JSON formatting
        msg = {
            "id": 1, 
            "method": "Page.navigate", 
            "params": {"url": url}
        }
        
        ws.send(json.dumps(msg))
        
        # Wait for response
        response = ws.recv()
        ws.close()
        
        logger.info(f"Browser navigated to: {url}")
        return True
        
    except Exception as e:
        logger.error(f"Navigation error: {e}")
        return False


@app.route("/set-rotation", methods=["POST"])
@require_api_key
def api_set_rotation():
    """Set screen rotation endpoint - rotation persists across reboots"""
    try:
        data = request.get_json()
        if not data or "rotation" not in data:
            logger.error("Missing 'rotation' field in request")
            return jsonify({"error": "Missing 'rotation' field"}), 400
        
        rotation = data["rotation"].strip().lower()
        
        try:
            display = set_screen_rotation(rotation)
            logger.info(f"Successfully set screen rotation to: {rotation}")
            return jsonify({
                "status": "success", 
                "rotation": rotation,
                "display": display,
                "message": f"Screen rotation set to {rotation} (persists across reboots)"
            }), 200
            
        except ValueError as e:
            logger.error(f"Invalid rotation value: {rotation}")
            return jsonify({"error": str(e)}), 400
        except Exception as e:
            logger.error(f"Failed to set screen rotation: {e}")
            return jsonify({"error": f"Failed to set rotation: {str(e)}"}), 500
        
    except Exception as e:
        logger.error(f"Unexpected error in set_rotation: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/get-rotation", methods=["GET"])
@require_api_key
def api_get_rotation():
    """Get current screen rotation endpoint"""
    try:
        current_rotation = get_screen_rotation()
        return jsonify({
            "rotation": current_rotation,
            "valid_rotations": ["normal", "left", "right", "inverted"]
        }), 200
    except Exception as e:
        logger.error(f"Error getting screen rotation: {e}")
        return jsonify({"error": "Internal server error"}), 500
@require_api_key
def api_get_url():
    """Get current URL endpoint"""
    try:
        current_url = get_url()
        return jsonify({"url": current_url}), 200
    except Exception as e:
        logger.error(f"Error getting URL: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/set-url", methods=["POST"])
@require_api_key
def api_set_url():
    """Set URL endpoint with validation - URL persists across reboots"""
    try:
        data = request.get_json()
        if not data or "url" not in data:
            logger.error("Missing 'url' field in request")
            return jsonify({"error": "Missing 'url' field"}), 400
        
        new_url = data["url"].strip()
        
        if not is_valid_url(new_url):
            logger.error(f"Invalid URL format: {new_url}")
            return jsonify({"error": "Invalid URL format"}), 400
        
        # Save URL to config file (persists across reboots)
        try:
            set_url(new_url)
        except Exception as e:
            logger.error(f"Failed to save URL: {e}")
            return jsonify({"error": f"Failed to save URL: {str(e)}"}), 500
        
        # Try navigation first, fallback to restart
        if not navigate_browser(new_url):
            logger.info("Navigation failed, restarting browser")
            if not start_browser(new_url):
                logger.error("Failed to start browser with new URL")
                return jsonify({"error": "Failed to start browser"}), 500
        
        logger.info(f"Successfully set URL to: {new_url}")
        return jsonify({
            "status": "success", 
            "url": new_url,
            "message": "URL set and saved to config (persists across reboots)"
        }), 200
        
    except ValueError as e:
        logger.error(f"ValueError in set_url: {e}")
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        logger.error(f"Unexpected error in set_url: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/restart-chromium", methods=["POST"])
@require_api_key
def api_restart_chromium():
    """Restart Chromium endpoint"""
    try:
        url = get_url()
        if start_browser(url):
            return jsonify({"status": "success", "url": url}), 200
        else:
            return jsonify({"error": "Failed to restart browser"}), 500
    except Exception as e:
        logger.error(f"Error restarting Chromium: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/reboot-system", methods=["POST"])
@require_api_key
def api_reboot_system():
    """Reboot system endpoint - now works since running as root"""
    try:
        logger.info("System reboot requested")
        # Use subprocess.Popen to avoid waiting for completion
        subprocess.Popen(["reboot"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return jsonify({"status": "rebooting"}), 200
    except Exception as e:
        logger.error(f"Error initiating reboot: {e}")
        return jsonify({"error": "Failed to reboot"}), 500



@app.route("/status", methods=["GET"])
@require_api_key
def api_status():
    """Get system status"""
    try:
        # Check if Chromium is running
        chromium_running, _, _ = run_cmd(["pgrep", "-f", "chromium"])
        
        # Check if X is running
        x_running, _, _ = run_cmd(["pgrep", "Xorg"])
        
        return jsonify({
            "status": "online",
            "chromium_running": chromium_running,
            "x_server_running": x_running,
            "current_url": get_url(),
            "current_rotation": get_screen_rotation(),
            "saved_rotation": get_saved_rotation(),
            "running_as": "root" if os.getuid() == 0 else f"user {os.getuid()}",
            "display": os.getenv("DISPLAY", "not set")
        }), 200
        
    except Exception as e:
        logger.error(f"Error getting status: {e}")
        return jsonify({"error": "Internal server error"}), 500


@app.route("/api-info", methods=["GET"])
def api_info():
    """Get API information (no auth required for setup)"""
    try:
        config = load_api_config()
        return jsonify({
            "message": "Kiosk API is running",
            "authentication_required": config.get("require_auth", True),
            "endpoints": [
                "GET /get-url",
                "POST /set-url",
                "GET /get-rotation",
                "POST /set-rotation",
                "POST /restart-chromium", 
                "POST /reboot-system",
                "GET /status",
                "GET /api-info"
            ],
            "note": "All endpoints except /api-info require X-API-Key header or api_key parameter",
            "running_as": "root" if os.getuid() == 0 else f"user {os.getuid()}"
        }), 200
    except Exception as e:
        logger.error(f"Error getting API info: {e}")
        return jsonify({"error": "Internal server error"}), 500


def mark_setup_complete():
    """Mark setup as complete"""
    try:
        ensure_directory_exists(os.path.dirname(SETUP_MARKER))
        with open(SETUP_MARKER, "w") as f:
            f.write(f"Setup completed at: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        
        # Set proper ownership
        subprocess.run(["chown", "root:root", SETUP_MARKER], stderr=subprocess.DEVNULL)
        
        logger.info("Setup marked as complete")
    except Exception as e:
        logger.error(f"Error marking setup complete: {e}")


def enable_autologin(user=KIOSK_USER):
    """Enable autologin for specified user"""
    override_dir = "/etc/systemd/system/getty@tty1.service.d"
    override_file = os.path.join(override_dir, "override.conf")

    if os.path.exists(override_file):
        logger.info("Autologin already configured.")
        return

    logger.info(f"Enabling autologin for user '{user}'...")
    try:
        subprocess.run(["mkdir", "-p", override_dir], check=True)
        content = f"""[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin {user} --noclear %I $TERM
"""
        with open("/tmp/override.conf", "w") as f:
            f.write(content)

        subprocess.run(["mv", "/tmp/override.conf", override_file], check=True)
        subprocess.run(["systemctl", "daemon-reexec"], check=True)
        logger.info("Autologin enabled for tty1.")
        
    except Exception as e:
        logger.error(f"Failed to enable autologin: {e}")
        raise


def detect_chromium_path():
    """Detect Chromium binary location"""
    global CHROMIUM_PATH
    
    possible_paths = [
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser", 
        "/snap/bin/chromium",
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable"
    ]
    
    for path in possible_paths:
        if os.path.exists(path):
            CHROMIUM_PATH = path
            logger.info(f"Found Chromium at: {path}")
            return True
    
    # Check if chromium is available via snap
    ok, stdout, stderr = run_cmd(["which", "chromium"])
    if ok and stdout:
        CHROMIUM_PATH = stdout
        logger.info(f"Found Chromium via which: {stdout}")
        return True
    
    logger.error("Chromium not found. Please install it with:")
    logger.error("    apt update && apt install chromium-browser")
    logger.error("    OR: snap install chromium")
    return False


def print_setup_info():
    """Print setup completion info with API key"""
    try:
        config = load_api_config()
        print("\n" + "="*60)
        print("KIOSK SETUP COMPLETE!")
        print("="*60)
        print(f"User '{KIOSK_USER}' created")
        print("System packages installed")
        print("Python packages installed") 
        print("Systemd service configured (runs as root)")
        print("Autologin enabled")
        print("Screen blanking disabled")
        print("\nAPI CONFIGURATION:")
        print(f"   API Key: {config['api_key']}")
        print(f"   Auth Required: {config['require_auth']}")
        print("\nAPI ENDPOINTS (after reboot):")
        print("   GET  http://<system-ip>/status?api_key=<key>")
        print("   GET  http://<system-ip>/get-url?api_key=<key>")
        print("   GET  http://<system-ip>/get-rotation?api_key=<key>")
        print("   POST http://<system-ip>/set-url?api_key=<key> (with JSON body)")
        print("   POST http://<system-ip>/set-rotation?api_key=<key> (with JSON body)")
        print("   POST http://<system-ip>/restart-chromium?api_key=<key>")
        print("   POST http://<system-ip>/reboot-system?api_key=<key>")
        print("\nAPI Examples")
        print("   Linux")
        print("""   curl -X POST "http://10.1.10.210/set-url?api_key=vXfHz" -H "Content-Type: application/json" -d '{"url":"http://google.com"}'""")        
        print("""   curl -X POST "http://10.1.10.210/set-rotation?api_key=vXfHz" -H "Content-Type: application/json"  -d '{"rotation":"left"}'""")
        print("   Windows")
        print(r'''   curl -X POST "http://10.1.10.210/set-url?api_key=vXfHz" -H "Content-Type: application/json" -d "{\"url\":\"http://google.com\"}" ''')
        print(r'''   curl -X POST "http://10.1.10.210/set-rotation?api_key=vXfHz" -H "Content-Type: application/json" -d "{\"rotation\":\"left\"}" ''')
        print("\nNEXT STEPS:")
        print("   1. sudo reboot")
        print(f"   2. System will auto-login as '{KIOSK_USER}'")
        print("   3. Kiosk service will start automatically as root")
        print("   4. Browser will display the configured URL")
        print("   5. API will be available on port 80")
        print("\nREGENERATE API KEY:")
        print("   sudo python3 /opt/kiosk/kiosk_api.py --regenerate-key")
        print("="*60)
        
    except Exception as e:
        logger.error(f"Error displaying setup info: {e}")


def main():
    """Main application entry point"""
    parser = argparse.ArgumentParser(description='Kiosk API Server')
    parser.add_argument('--regenerate-key', action='store_true',
                       help='Regenerate API key and exit')
    args = parser.parse_args()
    
    try:
        # Ensure log directory exists (with permission handling)
        try:
            ensure_directory_exists("/opt/kiosk")
        except PermissionError:
            logger.warning("Cannot create /opt/kiosk directory, using /tmp for logs")
        
        # Handle API key regeneration
        if args.regenerate_key:
            try:
                new_key = regenerate_api_key()
                print(f"New API key generated: {new_key}")
            except PermissionError:
                print("Permission denied. API key regeneration requires write access to /opt/kiosk/")
                print("   Please run as root: sudo python3 /opt/kiosk/kiosk_api.py --regenerate-key")
                sys.exit(1)
            return
        
        if not os.path.exists(SETUP_MARKER):
            # Check if running as root for setup
            if os.getuid() != 0:
                print("Setup must be run as root!")
                print("   Please run: sudo python3 /opt/kiosk/kiosk_api.py")
                sys.exit(1)
                
            # First boot setup
            logger.info("Starting first-time setup...")
            
            # Create kiosk user (for autologin, but service runs as root)
            create_kiosk_user()
            
            ensure_system_packages()
            ensure_python_packages()
            create_systemd_service(user=KIOSK_USER)
            enable_autologin(KIOSK_USER)
            disable_screen_blanking()
            
            # Initialize API config BEFORE setting up permissions
            load_api_config()  # This will create the config if it doesn't exist
            
            # Set up permissions AFTER all files are created
            setup_kiosk_permissions()
            
            mark_setup_complete()
            print_setup_info()
            
            logger.info("Setup complete. Please reboot the system.")
            sys.exit(0)

        # Detect Chromium binary
        if not detect_chromium_path():
            sys.exit(1)

        # Normal runtime
        logger.info("Starting kiosk application...")
        
        # Check if running as root (required for port 80)
        if os.getuid() != 0:
            logger.error("Kiosk API must run as root for port 80 access and system commands")
            logger.error("The systemd service should handle this automatically")
            sys.exit(1)

        # Load API configuration
        config = load_api_config()
        logger.info(f"API authentication: {'enabled' if config['require_auth'] else 'disabled'}")
        
        if not start_gui_if_needed():
            logger.error("Failed to start GUI components")
            sys.exit(1)
        
        # Get URL and start browser
        url = get_url()
        logger.info(f"Starting browser with URL: {url}")
        
        if not start_browser(url):
            logger.error("Failed to start browser")
            # Don't exit, continue with API server
            logger.warning("Continuing with API server despite browser failure")
        else:
            logger.info("Browser started successfully")
        
        logger.info("Kiosk API running at http://<system-ip>:80")
        logger.info("Use /api-info endpoint to see available endpoints")
        
        # Start Flask app on port 80 (should work now as root)
        try:
            app.run(host="0.0.0.0", port=80, debug=False)
        except PermissionError:
            logger.error("Permission denied binding to port 80 even as root. Trying port 8080...")
            app.run(host="0.0.0.0", port=8080, debug=False)
        
    except KeyboardInterrupt:
        logger.info("Kiosk API shutting down...")
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()