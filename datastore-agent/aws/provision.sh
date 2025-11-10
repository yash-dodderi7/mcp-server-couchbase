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
DEFAULT_USER="ec2-user"
HOME_DIR="/home/${DEFAULT_USER}"
PROCESS_EXPORTER_VERSION="0.8.7"
NODE_EXPORTER_VERSION="1.9.1"
PROCESS_EXPORTER_PACKAGE="process-exporter_${PROCESS_EXPORTER_VERSION}_linux_${PRODUCT_ARCH}"
NODE_EXPORTER_PACKAGE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${PRODUCT_ARCH}"

## Run security update
yum update --security -y

# Update journald
mv "${TMP_DIR}"/journald.conf /etc/systemd/journald.conf
chown root:root /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf

# Create couchbase user
useradd couchbase && usermod -a -G systemd-journal couchbase && usermod -a -G couchbase ${DEFAULT_USER}

# Disable swap
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
#     ntp: ntpdate, ntpq
yum install -y jq lshw lsof net-tools nmap-ncat ntp numactl sysstat tzdata wget

# Install Couchbase
yum install -y "${TMP_DIR}"/"${COUCHBASE_SERVER_PKG}"

# Install and start node exporter
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}.tar.gz" -P "${TMP_DIR}"/
tar xvfz "${TMP_DIR}"/"${NODE_EXPORTER_PACKAGE}".tar.gz -C "${HOME_DIR}" --strip-components=1 "${NODE_EXPORTER_PACKAGE}"/node_exporter
chown ${DEFAULT_USER}:${DEFAULT_USER} "${HOME_DIR}"/node_exporter
mv "${TMP_DIR}"/node-exporter.service /lib/systemd/system/node-exporter.service
systemctl enable node-exporter.service

# Install and enable process exporter
wget "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PACKAGE}.rpm" -P "${TMP_DIR}"/
yum install -y "${TMP_DIR}"/"${PROCESS_EXPORTER_PACKAGE}".rpm
mv "${TMP_DIR}"/process-exporter.service /lib/systemd/system/process-exporter.service
systemctl enable process-exporter.service

# Install & configure dp-observer
install_agent datastore-agent
install_agent dp-observer
install_agent dp-runtime-agent

# cleanup after installations
yum clean all -y
rm -rf "${TMP_DIR}"/*.gz
rm -rf "${TMP_DIR}"/*.service
rm -rf "${TMP_DIR}"/provision.sh
rm -rf "${TMP_DIR}"/*.rpm
