# =============================================================================
# Vaultwarden – Environment Distribution File
# Copy this file to ".env" and fill in your values before starting the stack.
#
#   cp env.dist .env
# =============================================================================

# -----------------------------------------------------------------------------
# Docker Image
# -----------------------------------------------------------------------------

# Vaultwarden server image version. Pin to a specific release for reproducibility.
# See releases: https://github.com/dani-garcia/vaultwarden/releases
VERSION=1.35.0

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

# Port binding for the Vaultwarden container.
# Format: <bind_address>:<host_port>  — the container always listens on port 80.
# Bind to 127.0.0.1 when running behind a reverse proxy (recommended).
EXPORT_PORT=127.0.0.1:8080

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

# Host path for persistent Vaultwarden data (SQLite database, attachments, icons).
DATA=./vaultwarden-data

# -----------------------------------------------------------------------------
# General Settings
# -----------------------------------------------------------------------------

# Enable WebSocket support for real-time sync notifications across clients.
WEBSOCKET_ENABLED=true

# Allow new user registrations via the web interface.
# Set to "false" once all intended users have created their accounts.
SIGNUPS_ALLOWED=true

# Public-facing URL of your Vaultwarden instance.
# Must match the domain configured in your reverse proxy.
DOMAIN=https://vault.example.com

# -----------------------------------------------------------------------------
# Signup Domain Whitelist
# -----------------------------------------------------------------------------

# Restrict self-registration to specific email domains (comma-separated).
# Only users whose email matches one of these domains may register.
# Leave empty to allow any domain (if SIGNUPS_ALLOWED is true).
SIGNUPS_DOMAINS_WHITELIST=example.com,example.org

# -----------------------------------------------------------------------------
# SMTP / Email Settings
# -----------------------------------------------------------------------------

# Hostname of your outbound SMTP server
SMTP_HOST=mail.example.com

# SMTP port — common values:
#   25  → STARTTLS (relay)
#   587 → STARTTLS (submission, recommended)
#   465 → Implicit TLS / SSL
SMTP_PORT=587

# Encryption method for the SMTP connection:
#   "starttls"  → upgrades plain connection to TLS (ports 25/587)
#   "force_tls" → connects directly over TLS (port 465)
#   "off"       → no encryption (not recommended)
SMTP_SECURITY=starttls

# Sender address shown in outgoing emails (e.g. invitations, 2FA codes)
SMTP_FROM=noreply@vault.example.com

# SMTP authentication credentials
SMTP_USERNAME=mail-out@example.com
SMTP_PASSWORD=your-smtp-password-here

# -----------------------------------------------------------------------------
# Admin Panel Token  *** REQUIRED — must not be empty ***
# -----------------------------------------------------------------------------
#
# Secures the /admin panel. An Argon2id hash is strongly recommended over a
# plain-text password.
#
# How to generate the hash:
#
#   1. Install the "argon2" CLI tool:
#        Debian/Ubuntu:  sudo apt install argon2
#        macOS:          brew install argon2
#
#   2. Run the following command, replacing "MySecretPassword" with your chosen password:
#        echo -n "MySecretPassword" | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4
#
#   3. Copy the full output string (starting with "$argon2id$...") and paste it below.
#
# Note: When using the hash in the .env file, wrap it in single quotes to prevent
# shell interpretation of special characters.
#
ADMIN_TOKEN='$argon2id$v=19$m=65540,t=3,p=4$your-generated-hash-here' 
