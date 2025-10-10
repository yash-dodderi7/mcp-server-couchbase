#!/bin/bash -ex

sudo mv /tmp/journald.conf /etc/systemd/journald.conf
sudo chown root:root /etc/systemd/journald.conf
sudo chmod 755 /etc/systemd/journald.conf

# run unattended-upgrade to apply kernel and security patches
# then disable it so that it so that it doesn't cause unexpected side effect in production
sudo apt update
sudo unattended-upgrade
sudo systemctl disable --now unattended-upgrades.service
sudo sed -i 's/^APT::Periodic::Unattended-Upgrade\s*"\?1"\?;/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades

# Install dependent packages
sudo apt-get install -y jq unzip wget
curl -LsSf https://astral.sh/uv/install.sh | sh
source $HOME/.local/bin/env

# Configure sudo permissions for ubuntu user to modify system files
sudo mv /tmp/vulcan-metrics-collector-sudoer /etc/sudoers.d/vulcan-metrics-collector
sudo chown root:root /etc/sudoers.d/vulcan-metrics-collector
sudo chmod 0440 /etc/sudoers.d/vulcan-metrics-collector

# Create couchbase user
sudo useradd couchbase && sudo usermod -a -G systemd-journal couchbase && sudo usermod -a -G couchbase ubuntu

# Install and enable vulcan-metrics-collector
mkdir /home/ubuntu/vulcan
touch /home/ubuntu/vulcan/vulcan_dev.log
chmod +w /home/ubuntu/vulcan/vulcan_dev.log
unzip /tmp/metrics-collector.zip -d /home/ubuntu/vulcan/.
rm -f /tmp/metrics-collector.zip
cd /home/ubuntu/vulcan
uv venv --python 3.11 --python-preference only-managed
mv /tmp/start-vulcan-metrics-collector.sh .venv/bin/.
source .venv/bin/activate
python -m ensurepip --upgrade --default-pip
pip install *.whl
sudo mv /tmp/vulcan-metrics-collector.service /lib/systemd/system/vulcan-metrics-collector.service
sudo systemctl enable vulcan-metrics-collector.service
sudo chown -R ubuntu:ubuntu /home/ubuntu/vulcan

# Install and start node exporter
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}.tar.gz" -P /tmp/
tar xvfz /tmp/"${NODE_EXPORTER_PACKAGE}".tar.gz -C /home/ubuntu/ --strip-components=1 "${NODE_EXPORTER_PACKAGE}"/node_exporter
chown ubuntu:ubuntu /home/ubuntu/node_exporter
sudo mv /tmp/node-exporter.service /lib/systemd/system/node-exporter.service
sudo systemctl enable node-exporter.service

# Install and enable process exporter
wget "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PACKAGE}.deb" -P /tmp/
sudo apt install -y /tmp/"${PROCESS_EXPORTER_PACKAGE}".deb
sudo mv /tmp/process-exporter.service /lib/systemd/system/process-exporter.service
sudo systemctl enable process-exporter.service

# install and enable observer service
sudo mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service
sudo mv /tmp/dp-observer.gz /home/ubuntu/ && sudo gunzip /home/ubuntu/dp-observer.gz
sudo chmod +x /home/ubuntu/dp-observer && sudo systemctl enable dp-observer.service
