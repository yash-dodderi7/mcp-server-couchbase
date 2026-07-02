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

mv /tmp/journald.conf /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf

apt update

# AV-133308: switch to the GA LTS kernel series (6.8). The rolling cloud
# kernel (6.17) has a TCP receive-buffer regression (AV-133015 / MB-70640);
# the GA series predates it and receives security updates for the LTS
# lifetime. The rolling metas are removed and blocked so nothing (including
# unattended-upgrade below) can cross-grade the kernel to a new series.
# The old kernel's own packages are purged at the end of provisioning since
# the build VM is still running that kernel and may need its modules.
export DEBIAN_FRONTEND=noninteractive
OLD_KERNEL_SERIES="$(uname -r | cut -d. -f1-2)"
apt update
apt install -y "linux-${CLOUD_PROVIDER}-lts-24.04"
if [[ ${OLD_KERNEL_SERIES} != "6.8" ]]; then
    apt remove -y "linux-${CLOUD_PROVIDER}" "linux-image-${CLOUD_PROVIDER}" "linux-headers-${CLOUD_PROVIDER}"
fi
cat > /etc/apt/preferences.d/99-couchbase-kernel-pin <<EOF
Package: linux-${CLOUD_PROVIDER} linux-image-${CLOUD_PROVIDER} linux-headers-${CLOUD_PROVIDER} linux-tools-${CLOUD_PROVIDER} linux-modules-extra-${CLOUD_PROVIDER} linux-cloud-tools-${CLOUD_PROVIDER}
Pin: version *
Pin-Priority: -1
EOF

# run unattended-upgrade to apply kernel and security patches
# then disable it so that it so that it doesn't cause unexpected side effect in production
apt install -y unattended-upgrades
unattended-upgrade
systemctl disable --now unattended-upgrades.service
sed -i 's/^APT::Periodic::Unattended-Upgrade\s*"\?1"\?;/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades


# Create couchbase user
echo "${DEFAULT_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dpapps
id couchbase &>/dev/null || useradd couchbase
usermod -a -G systemd-journal couchbase
usermod -a -G couchbase ${DEFAULT_USER}

echo "vm.swappiness = 0" >> /etc/sysctl.conf
sysctl vm.swappiness=0

apt install -y iptables jq lshw lsof ncat net-tools nmap ntp numactl rsync sysstat tzdata wget nvme-cli

export INSTALL_DONT_START_SERVER=1
apt install -y "${TMP_DIR}"/"${COUCHBASE_SERVER_PKG}"
mkdir -p /data
chown -R ${DEFAULT_USER}:${DEFAULT_USER} /data

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

# Install & configure various agents
install_agent datastore-agent
install_agent dp-observer
install_agent dp-runtime-agent

# Cleanup leftover files from tmp
rm -f "${TMP_DIR}"/dp-*
rm -f "${TMP_DIR}"/*.deb
rm -f "${TMP_DIR}"/*.gz

# APT cleanup
# AV-133308: purge the old rolling kernel now that provisioning no longer
# needs the running kernel's modules. Grub defaults to the highest version
# present, so the newer series must not remain in the image.
if [[ ${OLD_KERNEL_SERIES} != "6.8" ]]; then
    apt remove -y --purge "^linux-(image|image-unsigned|modules|modules-extra|headers|tools|cloud-tools)-${OLD_KERNEL_SERIES/./\\.}\..*"
fi

apt autoremove -y
apt clean
rm -f /var/cache/apt/pkgcache.bin /var/cache/apt/srcpkgcache.bin

# AV-133308: fail the build unless the image will boot a 6.8 kernel and only a
# 6.8 kernel. Packer does not reboot mid-build, so the VM is still running the
# base kernel here -- we assert on the INSTALLED kernel image set (what grub
# will boot), not `uname -r`. The "linux-image-[0-9]*" glob matches only
# versioned kernels (e.g. linux-image-6.8.0-1057-aws), never the metas.
installed_kernels=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '$2=="installed"{print $1}')
if [[ -z ${installed_kernels} ]]; then
    echo "AV-133308: no kernel image installed; refusing to complete." >&2
    exit 1
fi
unexpected_kernels=$(echo "${installed_kernels}" | grep -v '^linux-image-6\.8\.' || true)
if [[ -n ${unexpected_kernels} ]]; then
    echo "AV-133308: non-6.8 kernel image(s) still installed; refusing to complete:" >&2
    echo "${unexpected_kernels}" >&2
    exit 1
fi
echo "AV-133308: verified installed kernel(s): ${installed_kernels//$'\n'/ }"
