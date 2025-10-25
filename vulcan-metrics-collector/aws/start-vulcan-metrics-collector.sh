#!/bin/bash

# ${!var} is a little-known bashism that says "expand $var and then
# use that as a variable name and expand it"

# check if variable is set
chk_set() {
    local var=$1
    local err_msg="$2"
    if [[ -z "${!var}" ]]; then
        echo "$err_msg"
        echo "Exiting..."
        exit 1
    fi
}

# Add or update environment variable in profile
update_profile_env() {
    local var=$1
    local profile_file="/etc/profile.d/vulcan_metrics_collector.sh"

    if [[ ! -f "$profile_file" ]]; then
        sudo touch "$profile_file"
        sudo chmod 644 "$profile_file"
    fi

    if ! grep -q "^export ${var}=" "$profile_file"; then
        echo "export ${var}=\"${!var}\"" | sudo tee -a ${profile_file} >/dev/null
    fi
}

# Main
[ -r /etc/profile.d/vulcan_metrics_collector.sh ] && source /etc/profile.d/vulcan_metrics_collector.sh

# Get a token for IMDSv2 (valid for 6 hours)
TOKEN=$(wget -qO- --method=PUT --header="X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    http://169.254.169.254/latest/api/token)

# Use the token to fetch user-data
USER_DATA=$(wget -qO- --header="X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/user-data)

# Check if USER_DATA is empty
chk_set USER_DATA "Error: USER_DATA is empty. No user-data found from instance metadata."

# Check if it's valid JSON using jq
if echo "$USER_DATA" | jq . >/dev/null 2>&1; then
    echo "$USER_DATA" | jq .

    VULCAN_WORKFLOW_INPUT=$(echo "$USER_DATA" | jq -r '.workflow_input')

    # Validate VULCAN_WORKFLOW_INPUT
    chk_set VULCAN_WORKFLOW_INPUT "Error: VULCAN_WORKFLOW_INPUT is empty"

    echo "Setting VULCAN_WORKFLOW_INPUT as environment variable..."
    update_profile_env VULCAN_WORKFLOW_INPUT

    # Check and update for EXTRA_HOSTS in profile and /etc/hosts
    EXTRA_HOSTS=$(echo "$USER_DATA" | jq -r '.extra_hosts // empty')
    if [ -n "$EXTRA_HOSTS" ]; then
        # Check and add EXTRA_HOSTS if not present
        echo "Setting EXTRA_HOSTS as environment variable..."
        update_profile_env EXTRA_HOSTS

        # Only append to /etc/hosts if not already present
        # Split EXTRA_HOSTS by comma and process each host entry
        IFS=',' read -ra host_entries <<< "$EXTRA_HOSTS"
        for host_entry in "${host_entries[@]}"; do
            # Trim whitespace from the host entry
            host_entry=$(echo "$host_entry" | xargs)
            if ! grep -Fxq "$host_entry" /etc/hosts; then
                echo "$host_entry" | sudo tee -a /etc/hosts >/dev/null
                echo "Added: $host_entry"
            else
                echo "Already exists: $host_entry"
            fi
        done
        echo "Finished updating /etc/hosts"
    else
        echo "Not updating /etc/hosts since EXTRA_HOSTS is not available."
    fi
    
    VULCAN_DIR=/home/ubuntu/vulcan
    echo "VULCAN_WORKFLOW_INPUT=\"$VULCAN_WORKFLOW_INPUT\"" | sudo tee -a /etc/environment > /dev/null
    # Use sudo to run dns-refresher with elevated privileges, so it can update /etc/hosts
    echo "Starting dns-refresher service..."
    sudo $VULCAN_DIR/.venv/bin/dns-refresher \
        > $VULCAN_DIR/vulcan_dns_refresher_service.log 2>&1 &

    echo "Starting metrics-collector service..."
    metrics-collector
else
    echo "User data is not a valid JSON:"
    echo "$USER_DATA"
    echo "Exiting..."
    exit 1
fi