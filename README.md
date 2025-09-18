# Universal Kiosk Management System

A complete kiosk solution for managing displays, URLs, and playlists across different hardware platforms (x86/ARM/Raspberry Pi). Features **URL playlist cycling with custom display times** and automatically optimizes for your hardware architecture.

## Quick Start

### One-Line Installation (Recommended)
For Raspberry PI start with Desktop OS with user named kiosk
```bash
bash <(curl -s https://raw.githubusercontent.com/zitlem/Kiosk-URL/master/kiosk-setup.sh)
```

### Manual Installation
```bash
# Download and setup
curl -s https://raw.githubusercontent.com/zitlem/Kiosk-URL/master/kiosk-setup.sh -o kiosk-setup.sh
chmod +x kiosk-setup.sh
sudo ./kiosk-setup.sh setup
sudo reboot
```

That's it! Your kiosk is ready with remote API management and URL playlist support.

## Files

- **`kiosk-setup.sh`** - Complete kiosk solution (setup + management + API + playlist)

## URL Management

### Single URL (Indefinite Display)
```bash
# Command line
kiosk set-url http://google.com

# API
curl -X POST "http://<kiosk-ip>/set-url?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"url":"http://google.com"}'
```

### Multiple URLs with Timers (Auto-Cycling)
```bash
# Command line
kiosk playlist-add http://google.com 60 "Google"
kiosk playlist-add http://github.com 45 "GitHub"
kiosk playlist-enable

# API - Add to playlist
curl -X POST "http://<kiosk-ip>/playlist-add?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"url":"http://google.com","display_time":60,"title":"Google"}'

# API - Replace entire playlist
curl -X POST "http://<kiosk-ip>/playlist-replace?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"url":"http://example.com","display_time":30,"title":"Example"}'
```

## System Management Commands

```bash
# System status and information
kiosk status                         # Show system status
kiosk get-url                        # Get current URL
kiosk get-api-key                    # Show API key

# URL management
kiosk set-url <URL>                  # Set single URL mode
kiosk get-rotation                   # Get current display orientation
kiosk set-display-orientation <orientation>  # Set display orientation

# Playlist management
kiosk playlist                       # Show current playlist
kiosk playlist-add <URL> [time] [title]     # Add URL to playlist
kiosk playlist-remove <index>        # Remove URL by index
kiosk playlist-replace <URL> [time] [title]  # Replace entire playlist
kiosk playlist-set <URL> [time] [title]     # Alias for playlist-replace
kiosk playlist-enable                # Enable playlist cycling
kiosk playlist-disable               # Disable playlist cycling

# Service control (root required)
sudo kiosk start                     # Start kiosk services
sudo kiosk stop                      # Stop kiosk services
sudo kiosk restart                   # Restart kiosk services
kiosk logs [kiosk|api]              # View service logs

# API key management (root required)
sudo kiosk regenerate-api-key        # Generate new API key

# Utilities
kiosk test-api                       # Test API endpoints
sudo kiosk install                   # Install script to system PATH
sudo kiosk uninstall                 # Completely remove kiosk system
kiosk help                          # Show command help
```

## Remote API Control

### System Status
```bash
curl "http://<kiosk-ip>/status?api_key=<key>"
```

### Single URL Control
```bash
# Set single URL (displays indefinitely)
curl -X POST "http://<kiosk-ip>/set-url?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"url":"http://google.com"}'
```

### Multiple URL Playlist
```bash
# Multiple URLs with custom display times
curl -X POST "http://<kiosk-ip>/set-url?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{
       "urls": [
         {"url": "http://google.com", "duration": 60, "title": "Google"},
         {"url": "http://github.com", "duration": 45, "title": "GitHub"}
       ]
     }'

# Simple URL list (30s default timing)
curl -X POST "http://<kiosk-ip>/set-url?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"urls": ["http://site1.com", "http://site2.com"]}'
```

### Display Orientation & Service Control
```bash
# Get current display orientation
curl "http://<kiosk-ip>/get-rotation?api_key=<key>"

# Set display orientation
curl -X POST "http://<kiosk-ip>/set-display-orientation?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"orientation":"left"}'

# Service management
curl -X POST "http://<kiosk-ip>/start?api_key=<key>"
curl -X POST "http://<kiosk-ip>/stop?api_key=<key>"
curl -X POST "http://<kiosk-ip>/restart?api_key=<key>"

# View logs
curl "http://<kiosk-ip>/logs?api_key=<key>"

# Get API info
curl "http://<kiosk-ip>/api-info?api_key=<key>"
```

### Playlist Management
```bash
# Get current playlist
curl "http://<kiosk-ip>/playlist?api_key=<key>"

# Add to playlist
curl -X POST "http://<kiosk-ip>/playlist-add?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"url":"http://example.com","display_time":30,"title":"Example"}'

# Remove from playlist
curl -X POST "http://<kiosk-ip>/playlist-remove?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"index":0}'

# Replace entire playlist
curl -X POST "http://<kiosk-ip>/playlist-replace?api_key=<key>" \
     -H "Content-Type: application/json" \
     -d '{"url":"http://example.com","display_time":30,"title":"Example"}'

# Clear playlist
curl -X POST "http://<kiosk-ip>/playlist-clear?api_key=<key>"

# Enable/disable playlist cycling
curl -X POST "http://<kiosk-ip>/playlist-enable?api_key=<key>"
curl -X POST "http://<kiosk-ip>/playlist-disable?api_key=<key>"
```

## Architecture Support

- **x86/x64**: Intel/AMD systems with full performance optimization
- **ARM**: Generic ARM boards with memory/power optimizations  
- **Raspberry Pi**: Specialized RPi optimizations with GPU acceleration

The script automatically detects your hardware and applies optimal settings.

## Advanced Features

### URL Playlist System
- **Single URL Mode**: Display one URL indefinitely (perfect for permanent displays)
- **Multi-URL Mode**: Automatic cycling through multiple URLs with custom display times
- **Flexible Timing**: 5 seconds to 24 hours per URL
- **Seamless Navigation**: Uses Chrome DevTools Protocol for instant switching
- **Visual Management**: See current playlist status and cycling state

### Comprehensive Error Handling
- **Auto-recovery**: Browser crash detection and restart
- **Health monitoring**: Memory usage, display responsiveness  
- **Configuration backup**: Automatic backup before changes
- **Debug collection**: System state snapshots on errors
- **Retry mechanisms**: Smart retry with backoff for failed operations

### Security & Validation
- **Input validation**: URL format, timing, and security checks
- **API authentication**: Secure token-based access
- **Configuration validation**: Prevent invalid settings
- **Safe URLs only**: Blocks potentially malicious URL schemes

### Monitoring & Maintenance
- **Real-time monitoring**: Live system status updates
- **Health reports**: Comprehensive system analysis  
- **Log management**: Automatic log rotation and cleanup
- **Performance tracking**: Memory and resource monitoring

## Features

- ✅ **Single file solution** - Everything in one script
- ✅ **URL playlist system** - Multiple URLs with custom display times
- ✅ **Architecture-aware** - Automatic hardware optimization  
- ✅ **Remote management** - HTTP API for external control
- ✅ **Auto-recovery** - Browser crash detection and restart
- ✅ **Health monitoring** - System resource and status tracking
- ✅ **Configuration backup** - Automatic backup and restore
- ✅ **Comprehensive logging** - Detailed logging with rotation
- ✅ **Input validation** - Security and format validation
- ✅ **Persistent settings** - Configuration survives reboots
- ✅ **Professional setup** - Systemd services, proper logging
- ✅ **Security** - Token-based API authentication
- ✅ **Easy management** - Simple command-line interface

Perfect for **digital signage**, **cycling dashboards**, **information displays**, **interactive kiosks**, **presentations**, and any full-screen browser application with multiple content sources.

## Configuration

The system uses a unified configuration file at `/opt/kiosk/config.json`:

```json
{
  "kiosk": {
    "url": "http://example.com"
  },
  "display": {
    "orientation": "normal"
  },
  "api": {
    "api_key": "generated-key",
    "port": 80
  },
  "playlist": {
    "enabled": false,
    "cycling": false,
    "default_display_time": 30,
    "urls": [
      {
        "url": "http://site1.com",
        "display_time": 30,
        "title": "Site 1"
      }
    ]
  }
}
```

## Troubleshooting

### Check System Status
```bash
kiosk status
```

### View Logs
```bash
# Kiosk service logs
kiosk logs kiosk

# API service logs
kiosk logs api

# System logs
journalctl -u kiosk.service -f
journalctl -u kiosk-api.service -f
```

### Test API Connectivity
```bash
kiosk test-api
```

### Common Issues

1. **Browser not starting**: Check if Chromium is installed and X11 is running
2. **API not responding**: Verify kiosk-api.service is running
3. **Playlist not cycling**: Check that playlist is enabled and has multiple URLs
4. **Display orientation not working**: Restart kiosk service after orientation changes

### Manual Restart
```bash
sudo systemctl restart kiosk.service
sudo systemctl restart kiosk-api.service
```
