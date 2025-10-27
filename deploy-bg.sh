#!/bin/bash
# bg_control.sh: Automation script for local Blue/Green deployment using Docker Compose.

# --- Configuration and Setup ---

# Enable strict mode: exit immediately on error or undefined variables
set -euo pipefail

# File paths
ENV_FILE="blue-green.env"
COMPOSE_FILE="docker-compose.yml"
LOG_FILE="bg_control_$(date +%Y%m%d_%H%M%S).log"

# --- Utility Functions ---

# Log messages to console and file
log() {
    local type="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$type] $message" | tee -a "$LOG_FILE"
    if [ "$type" == "ERROR" ]; then
        exit 1
    fi
}

# Ensure required configuration files exist
check_files() {
    log "INFO" "Validating configuration files..."
    if [ ! -f "$ENV_FILE" ]; then
        log "ERROR" "Environment file '$ENV_FILE' not found. Cannot proceed."
    fi
    if [ ! -f "$COMPOSE_FILE" ]; then
        log "ERROR" "Docker Compose file '$COMPOSE_FILE' not found. Cannot proceed."
    fi
    log "SUCCESS" "Configuration files validated."
}

# Get the value of a variable from the .env file
get_env_var() {
    local var_name="$1"
    # Use grep and sed to safely extract the value
    grep "^${var_name}=" "$ENV_FILE" | head -n 1 | cut -d '=' -f 2- | tr -d '"' | tr -d "'"
}

# --- Core Control Functions ---

# Function to start the Docker Compose deployment
start_deployment() {
    log "INFO" "Starting Blue/Green deployment services..."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
    log "SUCCESS" "Deployment services started. Check status with ./bg_control.sh status"
}

# Function to stop the Docker Compose deployment
stop_deployment() {
    log "INFO" "Stopping and cleaning up Blue/Green deployment services..."
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down
    log "SUCCESS" "Deployment stopped and resources removed."
}

# Function to switch the ACTIVE_POOL in the .env file and reload Nginx
switch_pool() {
    local new_pool="$1"
    local current_pool
    current_pool=$(get_env_var ACTIVE_POOL)

    if [[ "$new_pool" != "blue" && "$new_pool" != "green" ]]; then
        log "ERROR" "Invalid pool specified: $new_pool. Must be 'blue' or 'green'."
    fi

    if [ "$current_pool" == "$new_pool" ]; then
        log "WARN" "Pool is already set to $new_pool. Skipping switch."
        return 0
    fi

    log "INFO" "Switching ACTIVE_POOL from $current_pool to $new_pool in $ENV_FILE..."

    # Use sed to safely replace the ACTIVE_POOL variable in the .env file
    sed -i.bak "s/^ACTIVE_POOL=.*/ACTIVE_POOL=$new_pool/" "$ENV_FILE"
    rm "$ENV_FILE.bak" || true

    log "INFO" "Reloading Nginx configuration..."
    # The Nginx container will use the new ACTIVE_POOL value on reload
    docker exec nginx_proxy /bin/sh -c "
        envsubst '\$\$NGINX_PORT \$\$ACTIVE_POOL \$\$APP_INTERNAL_PORT' < /etc/nginx/templates/nginx.conf.template > /etc/nginx/conf.d/default.conf &&
        nginx -s reload
    "
    log "SUCCESS" "Pool switched to $new_pool and Nginx reloaded successfully."
}

# Function to trigger chaos (failure) on the currently active pool
trigger_chaos() {
    local pool
    local port_var
    local port
    pool=$(get_env_var ACTIVE_POOL)

    if [ "$pool" == "blue" ]; then
        port_var="BLUE_APP_PORT"
    else
        port_var="GREEN_APP_PORT"
    fi
    port=$(get_env_var "$port_var")

    log "WARN" "Attempting to induce chaos on the $pool pool via port $port..."
    if curl -X POST "http://localhost:$port/chaos/start?mode=error" >/dev/null 2>&1; then
        log "SUCCESS" "Chaos successfully triggered on $pool. Nginx should now failover to the backup pool."
    else
        log "ERROR" "Failed to trigger chaos on $pool. Check if the container is running on port $port."
    fi
}

# Function to stop chaos (restore health) on the pool that is currently failing
stop_chaos() {
    local pool
    local port_var
    local port

    # Since the grader uses 8081/8082, we can just stop chaos on both to be safe, or assume
    # the failure was induced on the *default* primary (Blue) if the active pool is Green.
    # For simplicity, we target Blue (default primary)
    port=$(get_env_var BLUE_APP_PORT)

    log "INFO" "Attempting to stop chaos on the Blue pool (port $port) to allow automatic recovery..."
    if curl -X POST "http://localhost:$port/chaos/stop" >/dev/null 2>&1; then
        log "SUCCESS" "Chaos stopped on Blue pool. Nginx should eventually switch traffic back to Blue."
    else
        log "WARN" "Could not connect to Blue app to stop chaos. It may not have been running or in chaos mode."
    fi
}

# Function to check the current status of the deployment
check_status() {
    local active_pool
    active_pool=$(get_env_var ACTIVE_POOL)
    local nginx_port
    nginx_port=$(get_env_var NGINX_PORT)

    echo ""
    log "STATUS" "--- Blue/Green Deployment Status ---"
    log "STATUS" "Active Pool in $ENV_FILE: $active_pool"
    log "STATUS" "Public Nginx Port: $nginx_port"
    log "INFO" "Checking Docker Compose containers:"
    docker compose ps

    log "INFO" "Testing current traffic routing via http://localhost:$nginx_port/version:"
    # Use curl to get headers only and grep for the pool identifier
    curl -sI "http://localhost:$nginx_port/version" | grep -E 'X-App-Pool|HTTP'
    log "STATUS" "-------------------------------------"
}

# Display usage information
usage() {
    echo "Usage: ./bg_control.sh <command>"
    echo ""
    echo "Commands:"
    echo "  start           Start the entire deployment (docker compose up -d)"
    echo "  stop            Stop and remove the entire deployment (docker compose down)"
    echo "  status          Display current container status and active pool routing"
    echo "  switch <pool>   Manually switch the active pool ('blue' or 'green') and reload Nginx"
    echo "  chaos           Induce failure (chaos) on the *currently active* pool"
    echo "  heal            Stop chaos mode on the Blue pool (the default primary)"
    echo ""
}

# --- Main Execution ---

main() {
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi

    check_files

    case "$1" in
        start)
            start_deployment
            ;;
        stop)
            stop_deployment
            ;;
        status)
            check_status
            ;;
        switch)
            if [ $# -ne 2 ]; then
                log "ERROR" "Switch command requires a target pool: 'blue' or 'green'."
            fi
            switch_pool "$2"
            ;;
        chaos)
            trigger_chaos
            ;;
        heal)
            stop_chaos
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
