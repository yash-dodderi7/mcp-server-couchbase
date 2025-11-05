#!/bin/bash -e

# Function to install and enable dp-runtime-agent
install_agent() {
    local agent_name="$1"
    echo "Installing ${agent_name}..."
    mv /"${TMP_DIR}"/"${agent_name}".service /lib/systemd/system/"${agent_name}".service
    gunzip -c "${TMP_DIR}"/"${agent_name}".gz > "${HOME_DIR}"/"${agent_name}"
    chmod +x "${HOME_DIR}"/"${agent_name}"
    chown ubuntu:ubuntu "${HOME_DIR}"/"${agent_name}"
    systemctl enable "${agent_name}".service
    echo "${agent_name} installed and enabled successfully"
}

# Configuration and Constants
TMP_DIR="/tmp"
HOME_DIR="/home/ubuntu"
PROCESS_EXPORTER_VERSION="0.8.7"
NODE_EXPORTER_VERSION="1.9.1"

PROCESS_EXPORTER_PACKAGE="process-exporter_${PROCESS_EXPORTER_VERSION}_linux_${PRODUCT_ARCH}"
NODE_EXPORTER_PACKAGE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${PRODUCT_ARCH}"

# run unattended-upgrade to apply kernel and security patches
# then disable it so that it so that it doesn't cause unexpected side effect in production
apt update
apt install -y unattended-upgrades
unattended-upgrade
systemctl disable --now unattended-upgrades.service
sed -i 's/^APT::Periodic::Unattended-Upgrade\s*"\?1"\?;/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades

# Set default boot target
systemctl set-default multi-user.target

# Configure journald
mv "${TMP_DIR}"/journald.conf /etc/systemd/journald.conf
chown root:root /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf

# Create couchbase user
useradd couchbase
usermod -a -G systemd-journal couchbase
usermod -a -G couchbase ubuntu

echo "vm.swappiness = 0" >> /etc/sysctl.conf
sysctl vm.swappiness=0

# Install couchbase dependent packages
#   N1QL: tzdata
#   cbcollect_info:
#     lsof: lsof
#     lshw: lshw
#     sysstat: iostat, sar, mpstat
#     net-tools: ifconfig, arp, netstat
#     numactl: numactl
#      ntp: ntpdate, ntpq
apt install -y iptables jq lshw lsof ncat net-tools nmap ntp numactl rsync sysstat tzdata wget

# Install Couchbase
apt install -y "${TMP_DIR}"/"${PRODUCT_PKG_NAME}"

# Install and start node exporter
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}.tar.gz" -P "${TMP_DIR}"/
tar xvfz "${TMP_DIR}"/"${NODE_EXPORTER_PACKAGE}".tar.gz -C "${HOME_DIR}" --strip-components=1 "${NODE_EXPORTER_PACKAGE}"/node_exporter
chown ubuntu:ubuntu "${HOME_DIR}"/node_exporter
mv "${TMP_DIR}"/node-exporter.service /lib/systemd/system/node-exporter.service
systemctl enable node-exporter.service

# Install and enable process exporter
wget "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PACKAGE}.deb" -P "${TMP_DIR}"/
apt install -y "${TMP_DIR}"/"${PROCESS_EXPORTER_PACKAGE}".deb
mv "${TMP_DIR}"/process-exporter.service /lib/systemd/system/process-exporter.service
systemctl enable process-exporter.service

# Install & configure dp-observer
install_agent datastore-agent
install_agent dp-observer
install_agent dp-runtime-agent

# Cleanup leftover files from tmp
rm -f "${TMP_DIR}"/dp-*
rm -f "${TMP_DIR}"/*.deb
rm -f "${TMP_DIR}"/*.gz

# APT cleanup
apt autoremove -y
apt clean
rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin
