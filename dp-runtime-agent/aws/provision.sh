#!/bin/bash -ex

# run unattended-upgrade to apply kernel and security patches
# then disable it so that it so that it doesn't cause unexpected side effect in production
sudo apt update
sudo unattended-upgrade
sudo systemctl disable --now unattended-upgrades.service
sudo sed -i 's/^APT::Periodic::Unattended-Upgrade\s*"\?1"\?;/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades


sudo mv /tmp/journald.conf /etc/systemd/journald.conf
sudo chown root:root /etc/systemd/journald.conf
sudo chmod 755 /etc/systemd/journald.conf

# Install and enable dp-runtime-agent
gunzip -c /tmp/dp-runtime-agent.gz > /home/ubuntu/dp-runtime-agent
chmod +x /home/ubuntu/dp-runtime-agent
sudo mv /tmp/dp-runtime-agent.service /lib/systemd/system/dp-runtime-agent.service
sudo systemctl enable dp-runtime-agent.service
