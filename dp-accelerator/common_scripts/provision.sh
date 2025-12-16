#!/bin/bash -ex

# Function to install and enable agent
install_agent() {
    local agent_name="$1"
    echo "Installing ${agent_name}..."
    mv /"${TMP_DIR}"/"${agent_name}".service /lib/systemd/system/"${agent_name}".service
    gunzip -c "${TMP_DIR}"/"${agent_name}".gz > "${HOME_DIR}"/"${agent_name}"
    chmod +x "${HOME_DIR}"/"${agent_name}"
    chown ${DEFAULT_USER}:${DEFAULT_USER} "${HOME_DIR}"/"${agent_name}"
    systemctl enable "${agent_name}".service
    echo "${agent_name} installed and enabled successfully"
}

# Configuration and Constants
TMP_DIR="/tmp"
DEFAULT_USER="ubuntu"
HOME_DIR="/home/${DEFAULT_USER}"
PROCESS_EXPORTER_VERSION="0.8.7"
NODE_EXPORTER_VERSION="1.9.1"
PROCESS_EXPORTER_PACKAGE="process-exporter_${PROCESS_EXPORTER_VERSION}_linux_${PRODUCT_ARCH}"
NODE_EXPORTER_PACKAGE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${PRODUCT_ARCH}"

mv /tmp/journald.conf /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf

# run unattended-upgrade to apply kernel and security patches
# then disable it so that it so that it doesn't cause unexpected side effect in production
apt update
unattended-upgrade
systemctl disable --now unattended-upgrades.service
sed -i 's/^APT::Periodic::Unattended-Upgrade\s*"\?1"\?;/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades

# Install and start node exporter
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}.tar.gz" -P "${TMP_DIR}"/
tar xvfz "${TMP_DIR}"/"${NODE_EXPORTER_PACKAGE}".tar.gz -C "${HOME_DIR}" --strip-components=1 "${NODE_EXPORTER_PACKAGE}"/node_exporter
chown ${DEFAULT_USER}:${DEFAULT_USER} "${HOME_DIR}"/node_exporter
mv "${TMP_DIR}"/node-exporter.service /lib/systemd/system/node-exporter.service
systemctl enable node-exporter.service

# Install and enable process exporter
wget "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PACKAGE}.deb" -P "${TMP_DIR}"/
apt install -y "${TMP_DIR}"/"${PROCESS_EXPORTER_PACKAGE}".deb
mv "${TMP_DIR}"/process-exporter.service /lib/systemd/system/process-exporter.service
systemctl enable process-exporter.service

# Install a couple of dependencies for the log shipper script
apt-get install zip -y
snap install aws-cli --classic

# Create couchbase user
useradd couchbase && usermod -a -G systemd-journal couchbase && usermod -a -G couchbase ${DEFAULT_USER}

export INSTALL_DONT_START_SERVER=1
apt install -y "${TMP_DIR}"/"${COUCHBASE_SERVER_PKG}"
systemctl disable couchbase-server
mkdir -p /data
chown -R ${DEFAULT_USER}:${DEFAULT_USER} /data

# Install & configure dp agents
install_agent dp-accelerator
install_agent dp-observer

# Set logs and tmp directories
mkdir -p ${HOME_DIR}/logs && chmod 755 ${HOME_DIR}/logs && chown ${DEFAULT_USER} ${HOME_DIR}/logs
mkdir -p ${HOME_DIR}/tmp && chmod 755 ${HOME_DIR}/tmp && chown ${DEFAULT_USER} ${HOME_DIR}/tmp

# cleanup after installations
apt clean -y
apt autoremove -y
rm -rf "${TMP_DIR}"/*.gz
rm -rf "${TMP_DIR}"/*.service
rm -rf "${TMP_DIR}"/provision.sh
rm -rf "${TMP_DIR}"/*.deb
