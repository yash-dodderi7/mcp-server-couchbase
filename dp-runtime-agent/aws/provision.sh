#!/bin/bash -ex

## Run security update
yum update --security -y

# Install and start docker service
amazon-linux-extras install docker
usermod -a -G docker ec2-user
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

# Update journald
mv /tmp/journald.conf /etc/systemd/journald.conf
chown root:root /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf

# Create couchbase user
# dp-observer depends on this
useradd couchbase && usermod -a -G systemd-journal couchbase && usermod -a -G couchbase ec2-user

# Install and start node exporter
wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_PACKAGE}.tar.gz" -P /tmp/
tar xvfz /tmp/"${NODE_EXPORTER_PACKAGE}".tar.gz -C /home/ec2-user/ --strip-components=1 "${NODE_EXPORTER_PACKAGE}"/node_exporter
chown ec2-user:ec2-user /home/ec2-user/node_exporter
mv /tmp/node-exporter.service /lib/systemd/system/node-exporter.service
systemctl enable node-exporter.service

# Install and enable process exporter
wget "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/${PROCESS_EXPORTER_PACKAGE}.rpm" -P /tmp/
yum install -y /tmp/"${PROCESS_EXPORTER_PACKAGE}".rpm
mv /tmp/process-exporter.service /lib/systemd/system/process-exporter.service
systemctl enable process-exporter.service

# Install and enable dp-runtime-agent
gunzip -c /tmp/dp-runtime-agent.gz > /home/ec2-user/dp-runtime-agent
chown ec2-user:ec2-user /home/ec2-user/dp-runtime-agent
chmod +x /home/ec2-user/dp-runtime-agent
mv /tmp/dp-runtime-agent.service /lib/systemd/system/dp-runtime-agent.service
systemctl enable dp-runtime-agent.service

# install & enable dp-observer
mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service
mv /tmp/dp-observer.gz /home/ec2-user && gunzip /home/ec2-user/dp-observer.gz
chmod +x /home/ec2-user/dp-observer
chown ec2-user:ec2-user /home/ec2-user/dp-observer
systemctl enable dp-observer.service

# cleanup after installations
yum clean all -y
rm -rf /tmp/*.gz
rm -rf /tmp/*.service
rm -rf /tmp/provision.sh
rm -rf /tmp/*.rpm
