#!/bin/bash

# Function to install and enable dp-runtime-agent
install_agent() {
    local agent_name="$1"
    echo "Installing $agent_name..."
    sudo mv /tmp/$agent_name.service /lib/systemd/system/$agent_name.service
    sudo mv /tmp/$agent_name.gz /home/ec2-user
    sudo gunzip /home/ec2-user/$agent_name.gz
    sudo chmod +x /home/ec2-user/$agent_name
    sudo systemctl enable $agent_name.service
    echo "$agent_name installed and enabled successfully"
}

# Main
# Install and enable ai agents based on product
product_name=$1
product_version=$2
min_version="8.0.0"

case "$product_name" in
    "couchbase-server")
        if [[ "$(printf '%s\n' "$min_version" "$product_version" | sort -V | head -n1)" == "$min_version" ]]; then
            install_agent "dp-runtime-agent"
        fi
        ;;
    "datastore-agent")
        install_agent "dp-runtime-agent"
        install_agent "datastore-agent"
        ;;
esac
