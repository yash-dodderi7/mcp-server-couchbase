#!/bin/bash

[ -r /etc/profile.d/vulcan_metrics_collector.sh ] && source /etc/profile.d/vulcan_metrics_collector.sh

# Get a token for IMDSv2 (valid for 6 hours)
TOKEN=$(wget -qO- --method=PUT --header="X-aws-ec2-metadata-token-ttl-seconds: 21600" \
  http://169.254.169.254/latest/api/token)

# Use the token to fetch user-data
USER_DATA=$(wget -qO- --header="X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/user-data)

# Check if it's valid JSON using jq
if echo "$USER_DATA" | jq . >/dev/null 2>&1; then
    echo "$USER_DATA" | jq .

    VULCAN_WORKFLOW_INPUT=$(echo "$USER_DATA" | jq -r '.workflow_input')
    EXTRA_HOSTS=$(echo "$USER_DATA" | jq -r '.extra_hosts')

    # Validate VULCAN_WORKFLOW_INPUT
    if [ -z "$VULCAN_WORKFLOW_INPUT" ]; then
        echo "Error: VULCAN_WORKFLOW_INPUT is empty"
        echo "Exiting..."
        exit 1
    fi

    # Validate EXTRA_HOSTS
    if [ -z "$EXTRA_HOSTS" ]; then
        echo "Error: EXTRA_HOSTS is empty"
        echo "Exiting..."
        exit 1
    fi

    echo "Setting VULCAN_WORKFLOW_INPUT and EXTRA_HOSTS as environment variables..."

    # Check and add VULCAN_WORKFLOW_INPUT if not present
    if ! grep -q "^export VULCAN_WORKFLOW_INPUT=" /etc/profile.d/vulcan_metrics_collector.sh; then
        echo "export VULCAN_WORKFLOW_INPUT=\"$VULCAN_WORKFLOW_INPUT\"" | sudo tee -a /etc/profile.d/vulcan_metrics_collector.sh >/dev/null
    fi

    # Check and add EXTRA_HOSTS if not present
    if ! grep -q "^export EXTRA_HOSTS=" /etc/profile.d/vulcan_metrics_collector.sh; then
        echo "export EXTRA_HOSTS=\"$EXTRA_HOSTS\"" | sudo tee -a /etc/profile.d/vulcan_metrics_collector.sh >/dev/null
    fi

    echo "Adding extra hosts..."

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

    # Start Metrics Collector service
    metrics-collector
else
    echo "User data is not a valid JSON:"
    echo "$USER_DATA"
    echo "Exiting..."
    exit 1
fi
