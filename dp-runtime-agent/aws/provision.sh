#!/bin/bash -ex

# Function to install and enable agent
install_agent() {
    local agent_name="$1"
    local install_dir="$2"
    echo "Installing ${agent_name}..."
    mv "${TMP_DIR}"/"${agent_name}".service /lib/systemd/system/"${agent_name}".service
    gunzip -c "${TMP_DIR}"/"${agent_name}".gz > "${install_dir}"/"${agent_name}"
    chmod +x "${install_dir}"/"${agent_name}"
    chown ${DEFAULT_USER}:${DEFAULT_USER} "${install_dir}"/"${agent_name}"
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

# Install and start docker service
# Remove docker.io in case if they are installed
apt remove -y docker.io containerd runc || true
apt install -y ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install docker-ce -y
usermod -a -G docker ec2-user

# Run unattended-upgrade to apply kernel and security patches
# Then disable it so that it so that it doesn't cause unexpected side effect in production
unattended-upgrade
systemctl disable --now unattended-upgrades.service
sed -i 's/^APT::Periodic::Unattended-Upgrade\s*"\?1"\?;/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades

# Set default boot target
systemctl set-default multi-user.target

# Configure journald
mv "${TMP_DIR}"/journald.conf /etc/systemd/journald.conf
chown root:root /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf

# Start docker service
systemctl enable --now docker
for i in {1..60}; do
if docker info >/dev/null 2>&1; then
  echo "Docker daemon is running."
  break
else
  sleep 1
fi
done

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not responsive"
  exit 1
fi

# Grant ec2-user sudo access
# Create couchbase user
# hence, we need to check for its existence before creating it
echo "ec2-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dpapps
id couchbase &>/dev/null || useradd couchbase
usermod -a -G systemd-journal couchbase
usermod -a -G couchbase ec2-user

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

# Install and enable agents: dp-runtime-agent, dp-observer
install_agent dp-runtime-agent ${HOME_DIR}
install_agent dp-observer ${HOME_DIR}

# cleanup after installations
apt clean -y
apt autoremove -y
rm -rf "${TMP_DIR}"/*.gz
rm -rf "${TMP_DIR}"/*.service
rm -rf "${TMP_DIR}"/provision.sh
rm -rf "${TMP_DIR}"/*.deb
