# --- Dockerfile for ERPNext on Railway ---

# Start from the official ERPNext image
# This image already includes both 'frappe' and 'erpnext'
# We use v15 to match the base Frappe version
ARG ERPNEXT_VERSION=v15
FROM frappe/erpnext:${ERPNEXT_VERSION}

# Expose the default port for Railway
EXPOSE 8000

# The image's default command will run the server

#
# --- !! ADD THIS LINE !! ---
#
# This overrides the "USER frappe" from the base image
# so the start command runs as root, which is needed
# to fix volume permissions on Railway.
USER root
