#!/bin/bash -ex

# run unattended-upgrade to apply kernel and security patches
# then disable it so that it so that it doesn't cause unexpected side effect in production
apt update
unattended-upgrade
systemctl disable --now unattended-upgrades.service
sed -i 's/^APT::Periodic::Unattended-Upgrade\s*"\?1"\?;/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades


mv /tmp/journald.conf /etc/systemd/journald.conf
chown root:root /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf

# Create couchbase user
# dp-observer depends on this
useradd couchbase && sudo usermod -a -G systemd-journal couchbase && sudo usermod -a -G couchbase ubuntu

# Install and start node exporter
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}.tar.gz" -P /tmp/
tar xvfz /tmp/"${NODE_EXPORTER_PACKAGE}".tar.gz -C /home/ubuntu/ --strip-components=1 "${NODE_EXPORTER_PACKAGE}"/node_exporter
chown ubuntu:ubuntu /home/ubuntu/node_exporter
mv /tmp/node-exporter.service /lib/systemd/system/node-exporter.service
systemctl enable node-exporter.service

# Install and enable process exporter
wget "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PACKAGE}.deb" -P /tmp/
apt install -y /tmp/"${PROCESS_EXPORTER_PACKAGE}".deb
mv /tmp/process-exporter.service /lib/systemd/system/process-exporter.service
systemctl enable process-exporter.service

# Install and enable dp-runtime-agent
gunzip -c /tmp/dp-runtime-agent.gz > /home/ubuntu/dp-runtime-agent
chown ubuntu:ubuntu /home/ubuntu/dp-runtime-agent
chmod +x /home/ubuntu/dp-runtime-agent
mv /tmp/dp-runtime-agent.service /lib/systemd/system/dp-runtime-agent.service
systemctl enable dp-runtime-agent.service

# install & enable dp-observer
mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service
mv /tmp/dp-observer.gz /home/ubuntu && gunzip /home/ubuntu/dp-observer.gz
chmod +x /home/ubuntu/dp-observer
chown ubuntu:ubuntu /home/ubuntu/dp-observer
systemctl enable dp-observer.service
