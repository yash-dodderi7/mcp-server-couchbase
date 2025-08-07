#!/bin/bash -ex

mv /tmp/journald.conf /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf

# Set swappiness to 1 to avoid swapping excessively
echo "vm.swappiness = 1" >> /etc/sysctl.conf

# run unattended-upgrade to apply kernel and security patches
# then disable it so that it so that it doesn't cause unexpected side effect in production
apt update
unattended-upgrade
systemctl disable --now unattended-upgrades.service
sed -i 's/^APT::Periodic::Unattended-Upgrade\s*"\?1"\?;/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades

# Install and start docker service
apt install docker-ce -y
usermod -a -G docker ubuntu
systemctl start docker
echo "Waiting for Docker to become available (timeout: 60s)..."
timeout 60 bash -c '
  until docker info >/dev/null 2>&1; do
    sleep 1
  done
'

if [[ $? -ne 0 ]]; then
  echo "Docker did not become ready within 60 seconds."
  exit 1
fi

# Install gvisor and set it as default docker runtime
# reference: https://gvisor.dev/docs/user_guide/install/
pushd /tmp
wget https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/runsc
wget https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/runsc.sha512
wget https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/containerd-shim-runsc-v1
wget https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/containerd-shim-runsc-v1.sha512
sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512
rm -f *.sha512
chmod a+rx runsc containerd-shim-runsc-v1
mv runsc containerd-shim-runsc-v1 /usr/local/bin
/usr/local/bin/runsc install
systemctl reload docker
if ! docker info 2>/dev/null | grep -q 'io.containerd.runc'; then
  echo "'io.containerd.runc' is not loaded."
  exit 1
fi
popd

# Install and enable model-serving-agent
mv /tmp/${PRODUCT}.service /lib/systemd/system/${PRODUCT}.service
mv /tmp/${PRODUCT_PKG_NAME} /home/ubuntu/. && gunzip /home/ubuntu/${PRODUCT_PKG_NAME}
chown ubuntu:ubuntu /home/ubuntu/${PRODUCT_PKG_NAME%.*}
chmod 755 /home/ubuntu/${PRODUCT_PKG_NAME%.*}
sudo -u ubuntu ln -s /home/ubuntu/${PRODUCT_PKG_NAME%.*} /home/ubuntu/${PRODUCT} && chmod 755 /home/ubuntu/${PRODUCT}
systemctl enable ${PRODUCT}.service
systemctl reload docker
