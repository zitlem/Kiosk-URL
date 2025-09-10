# Kiosk API

A Python-based web kiosk system that automatically sets up a full-screen Chromium browser with remote management capabilities via REST API. Perfect for digital signage, information displays, and unattended kiosk deployments.

## Features

- **Automatic System Setup**: One-command installation and configuration
- **Full-Screen Kiosk Mode**: Chromium runs in true kiosk mode with no UI elements
- **Remote Management**: REST API for controlling the kiosk remotely
- **Screen Rotation**: Support for portrait/landscape orientations that persist across reboots
- **Auto-Login**: Automatic user login and kiosk startup
- **Screen Blanking Prevention**: Keeps display always on
- **Secure API**: API key authentication for all endpoints
- **System Integration**: Runs as systemd service with auto-restart
- **Cross-Platform**: Works on Debian-based Linux distributions

## Quick Start

1. **Download and run setup** (requires root privileges):

```bash
sudo apt update && sudo apt install python3-pip -y
```
```bash
pip3 install flask --break-system-packages
```

Only on Raspberry Pi?
```bash
sudo apt install x11-utils
```

Download and run in one command
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/vm/debian-vm.sh)"
# Download and run in one command
bash <(curl -s https://raw.githubusercontent.com/zitlem/Kiosk-URL/master/kiosk.sh)


```

```bash
sudo python3 kiosk_api.py
```

2. **Reboot the system**:
```bash
sudo reboot
```

3. **Access the API** (replace with your system's IP and the API key shown during setup):
```bash
curl "http://192.168.1.100/status?api_key=your_api_key_here"
```

## API Endpoints

All endpoints require authentication via `X-API-Key` header or `api_key` query parameter.

### URL Management
- `GET /get-url` - Get current displayed URL
- `POST /set-url` - Set new URL to display
  ```bash
  curl -X POST "http://kiosk-ip/set-url?api_key=KEY" \
    -H "Content-Type: application/json" \
    -d '{"url":"https://example.com"}'
  ```

### Screen Rotation
- `GET /get-rotation` - Get current screen rotation
- `POST /set-rotation` - Set screen rotation (normal, left, right, inverted)
  ```bash
  curl -X POST "http://kiosk-ip/set-rotation?api_key=KEY" \
    -H "Content-Type: application/json" \
    -d '{"rotation":"left"}'
  ```

### System Control
- `POST /restart-chromium` - Restart the browser
- `POST /reboot-system` - Reboot the entire system
- `GET /status` - Get system status and health check
- `GET /api-info` - Get API information (no auth required)

## Installation Details

### System Requirements
- Debian-based Linux distribution (Ubuntu, Raspberry Pi OS, etc.)
- Root access for initial setup
- Network connectivity
- Display connected via HDMI/VGA

### What Gets Installed
- **System packages**: X server, Openbox window manager, Chromium browser
- **Python packages**: Flask, requests, websocket-client
- **System user**: `kiosk` user for auto-login
- **Systemd service**: Auto-starting kiosk service
- **Configuration**: Screen blanking disabled, auto-login enabled

### File Structure
```
/opt/kiosk/
├── kiosk_api.py           # Main application
├── kiosk_url.txt          # Persisted URL setting
├── rotation_config.txt    # Persisted rotation setting
├── api_config.json        # API key and auth settings
├── start_kiosk.sh         # Startup wrapper script
├── disable_blanking.sh    # Screen blanking disable script
└── .setup_complete        # Setup completion marker
```

## Configuration

### API Key Management
View current API key:
```bash
sudo cat /opt/kiosk/api_config.json
```

Generate new API key:
```bash
sudo python3 /opt/kiosk/kiosk_api.py --regenerate-key
```

### Service Management
```bash
# Check service status
sudo systemctl status kiosk.service

# Restart service
sudo systemctl restart kiosk.service

# View logs
sudo journalctl -u kiosk.service -f
```

## Usage Examples

### Set Up Digital Signage
```bash
# Set URL to your dashboard
curl -X POST "http://kiosk-ip/set-url?api_key=KEY" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://dashboard.company.com"}'

# Set to landscape orientation
curl -X POST "http://kiosk-ip/set-rotation?api_key=KEY" \
  -H "Content-Type: application/json" \
  -d '{"rotation":"normal"}'
```

### Portrait Mode Setup
```bash
# Rotate screen for portrait displays
curl -X POST "http://kiosk-ip/set-rotation?api_key=KEY" \
  -H "Content-Type: application/json" \
  -d '{"rotation":"left"}'
```

### Health Monitoring
```bash
# Check if kiosk is running properly
curl "http://kiosk-ip/status?api_key=KEY" | jq
```

## Troubleshooting

### Common Issues

**Setup fails with permission errors:**
- Ensure you're running as root: `sudo python3 kiosk_api.py`

**Browser doesn't start:**
- Check if Chromium is installed: `which chromium-browser`
- View service logs: `sudo journalctl -u kiosk.service -f`

**API not accessible:**
- Verify service is running: `sudo systemctl status kiosk.service`
- Check firewall settings
- Confirm you're using the correct API key

**Screen doesn't rotate:**
- Verify X server is running: `ps aux | grep Xorg`
- Test rotation manually: `DISPLAY=:0 xrandr --output HDMI-1 --rotate left`

### Manual Recovery

**Reset to defaults:**
```bash
sudo rm -f /opt/kiosk/kiosk_url.txt /opt/kiosk/rotation_config.txt
sudo systemctl restart kiosk.service
```

**Reinstall service:**
```bash
sudo rm -f /opt/kiosk/.setup_complete
sudo python3 kiosk_api.py
sudo reboot
```

## Security Considerations

- API runs on port 80 and requires authentication
- All endpoints except `/api-info` require API key
- Service runs as root for system management capabilities
- Regenerate API key if compromised
- Consider firewall rules for production deployments

## Hardware Compatibility

### Tested Platforms
- Raspberry Pi 4 (Raspberry Pi OS)
- Ubuntu 20.04+ Desktop/Server
- Debian 11+ with desktop environment

### Display Outputs
- HDMI (primary)
- VGA (via adapters)
- DisplayPort (via adapters)

## Development

### Running in Development Mode
```bash
# Skip setup and run directly
export DISPLAY=:0
python3 kiosk_api.py
```

### API Testing
Use the included `/api-info` endpoint to explore available endpoints without authentication.

## License

This project is provided as-is for educational and commercial use. No warranty is provided.

## Contributing

This is a standalone kiosk solution. For bugs or feature requests, please test thoroughly in your environment before deploying to production systems.

---

## Quick Reference Card

| Action | Command |
|--------|---------|
| Initial Setup | `sudo python3 kiosk_api.py` |
| Set URL | `POST /set-url {"url":"https://example.com"}` |
| Rotate Screen | `POST /set-rotation {"rotation":"left"}` |
| Check Status | `GET /status` |
| Restart Browser | `POST /restart-chromium` |
| Reboot System | `POST /reboot-system` |
| New API Key | `sudo python3 /opt/kiosk/kiosk_api.py --regenerate-key` |