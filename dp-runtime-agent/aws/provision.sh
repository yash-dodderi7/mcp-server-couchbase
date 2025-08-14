#!/bin/bash -ex
sudo mv /tmp/journald.conf /etc/systemd/journald.conf
sudo chown root:root /etc/systemd/journald.conf
sudo chmod 755 /etc/systemd/journald.conf

sudo apt-get update
# Install dependent packages

# Install and enable dp-runtime-agent
mv /tmp/dp-runtime-agent /home/ubuntu/.
chmod +x /home/ubuntu/dp-runtime-agent
sudo mv /tmp/dp-runtime-agent.service /lib/systemd/system/dp-runtime-agent.service
sudo systemctl enable dp-runtime-agent.service
