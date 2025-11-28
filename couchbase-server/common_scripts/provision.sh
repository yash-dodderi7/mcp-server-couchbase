#!/bin/bash -e

# Configuration and Constants
TMP_DIR="/tmp"
PROCESS_EXPORTER_VERSION="0.8.7"
NODE_EXPORTER_VERSION="1.9.1"
PUSHGATEWAY_VERSION="1.11.0"

PROCESS_EXPORTER_PACKAGE="process-exporter_${PROCESS_EXPORTER_VERSION}_linux_${PRODUCT_ARCH}"
NODE_EXPORTER_PACKAGE="node_exporter-${NODE_EXPORTER_VERSION}.linux-${PRODUCT_ARCH}"
PUSHGATEWAY_PACKAGE="pushgateway-${PUSHGATEWAY_VERSION}.linux-${PRODUCT_ARCH}"

# Set couchbase base_dir
if [[ ${PRODUCT_SERVICE} == "couchbase-server" ]]; then
    BASE_DIR="/opt/couchbase"
else
    BASE_DIR="/opt/${PRODUCT_SERVICE}"
fi

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

# MB-66648 set nr_open to 1 billion
# we should revert this change if performance does not improve
sysctl -w fs.nr_open=1073741816

# MB-66648 disables LRU_GEN_ENABLED
# we should revert this change if performance does not improve
mv "${TMP_DIR}"/disable-mglru.service /etc/systemd/system/disable-mglru.service
systemctl enable disable-mglru.service
systemctl start disable-mglru.service

# MB-68110 disable kernel.split_lock
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="split_lock_detect=off /' /etc/default/grub
update-grub

# Grant ec2-user sudo access
# Create couchbase user
echo "ec2-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dpapps
useradd couchbase
usermod -a -G systemd-journal couchbase
usermod -a -G couchbase ec2-user

# Disable transparent huge pages
mv "${TMP_DIR}"/disable-thp.service /lib/systemd/system/disable-thp.service
chmod 755 /lib/systemd/system/disable-thp.service
systemctl start disable-thp.service
systemctl enable disable-thp.service

echo "vm.swappiness = 0" >> /etc/sysctl.conf
sysctl vm.swappiness=0

# MB-57636 configure keepalive settings
if [[ ${CLOUD_PROVIDER} == "gcp" ]]; then
    echo "net.ipv4.tcp_keepalive_time=480" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_keepalive_intvl=75" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_keepalive_probes=9" >> /etc/sysctl.conf
fi

# Install couchbase dependent packages
#   N1QL: tzdata
#   cbcollect_info:
#     lsof: lsof
#     lshw: lshw
#     sysstat: iostat, sar, mpstat
#     net-tools: ifconfig, arp, netstat
#     numactl: numactl
#      ntp: ntpdate, ntpq
apt install -y iptables jq lshw lsof ncat net-tools nmap ntp numactl rsync sysstat tzdata wget nvme-cli

# Install Couchbase
export INSTALL_DONT_START_SERVER=1
apt install -y "${TMP_DIR}"/"${PRODUCT_PKG_NAME}"

# Setup ns_server profile
mkdir -p /etc/couchbase.d
echo "${NS_SERVER_PROFILE}" > /etc/couchbase.d/config_profile
chmod 755 /etc/couchbase.d/config_profile
chown -R couchbase:couchbase /etc/couchbase.d

# Setup the directory for the TLS certificate and key
mkdir -p "${BASE_DIR}"/var/lib/couchbase/inbox/CA/
touch "${BASE_DIR}"/var/lib/couchbase/inbox/CA/ca.pem
touch "${BASE_DIR}"/var/lib/couchbase/inbox/chain.pem
touch "${BASE_DIR}"/var/lib/couchbase/inbox/pkey.key
chown -R ec2-user:couchbase "${BASE_DIR}"/var/lib/couchbase/inbox/
chmod 0640 "${BASE_DIR}"/var/lib/couchbase/inbox/CA/ca.pem
chmod 0640 "${BASE_DIR}"/var/lib/couchbase/inbox/chain.pem
chmod 0640 "${BASE_DIR}"/var/lib/couchbase/inbox/pkey.key
systemctl disable "${PRODUCT_SERVICE}"

# Install and start node exporter
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}.tar.gz" -P "${TMP_DIR}"/
tar xvfz "${TMP_DIR}"/"${NODE_EXPORTER_PACKAGE}".tar.gz -C /home/ec2-user/ --strip-components=1 "${NODE_EXPORTER_PACKAGE}"/node_exporter
chown ec2-user:ec2-user /home/ec2-user/node_exporter
mv "${TMP_DIR}"/node-exporter.service /lib/systemd/system/node-exporter.service
systemctl enable node-exporter.service

# Install and enable process exporter
wget "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PACKAGE}.deb" -P "${TMP_DIR}"/
apt install -y "${TMP_DIR}"/"${PROCESS_EXPORTER_PACKAGE}".deb
mv "${TMP_DIR}"/process-exporter.service /lib/systemd/system/process-exporter.service
systemctl enable process-exporter.service

# Install and enable pushgateway service
wget "https://github.com/prometheus/pushgateway/releases/download/v${PUSHGATEWAY_VERSION}/${PUSHGATEWAY_PACKAGE}.tar.gz" -P "${TMP_DIR}"/
tar xvfz "${TMP_DIR}"/"${PUSHGATEWAY_PACKAGE}".tar.gz -C /home/ec2-user/ --strip-components=1 "${PUSHGATEWAY_PACKAGE}"/pushgateway
chown ec2-user:ec2-user /home/ec2-user/pushgateway
mv "${TMP_DIR}"/pushgateway.service /lib/systemd/system/pushgateway.service
systemctl enable pushgateway.service

# Install and enable dp-agent or dp-backup
mv "${TMP_DIR}"/"${DP_SERVICE}".service /lib/systemd/system/"${DP_SERVICE}".service
gunzip -c "${TMP_DIR}"/"${DP_SERVICE}".gz > /home/ec2-user/"${DP_SERVICE}"
chmod +x /home/ec2-user/"${DP_SERVICE}"
systemctl enable "${DP_SERVICE}".service

# Install firewall service
mv "${TMP_DIR}"/dp-firewall.service /lib/systemd/system/dp-firewall.service
mv "${TMP_DIR}"/iptables-firewall.sh /home/ec2-user
chmod +x /home/ec2-user/iptables-firewall.sh
chown root:root /home/ec2-user/iptables-firewall.sh
systemctl start dp-firewall.service
systemctl enable dp-firewall.service

# Add imports directory
mkdir -p /home/ec2-user/imports
chown ec2-user:ec2-user /home/ec2-user/imports

# Install & configure dp-observer
mv "${TMP_DIR}"/dp-observer.service /lib/systemd/system/.
gunzip -c "${TMP_DIR}"/dp-observer.gz > /home/ec2-user/dp-observer
chmod +x /home/ec2-user/dp-observer
systemctl enable dp-observer.service

if [[ ${CLOUD_PROVIDER} == "aws" && ${PRODUCT_SERVICE} == "couchbase-server" && ${DP_SERVICE} == "dp-agent" ]]; then
    mv ${TMP_DIR}/dp-runtime-agent.service /lib/systemd/system/.
    mv ${TMP_DIR}/dp-runtime-agent.gz /home/ec2-user/.
    gunzip /home/ec2-user/dp-runtime-agent.gz
    chmod +x /home/ec2-user/dp-runtime-agent
    systemctl enable dp-runtime-agent.service
fi

# Cleanup leftover files from tmp
rm -f "${TMP_DIR}"/dp-*
rm -f "${TMP_DIR}"/*.deb
rm -f "${TMP_DIR}"/*.gz

# APT cleanup
apt autoremove -y
apt clean
rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin
