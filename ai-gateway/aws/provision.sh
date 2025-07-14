#!/bin/bash -ex

mv /tmp/journald.conf /etc/systemd/journald.conf
chmod 755 /etc/systemd/journald.conf
apt-get update

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

# Create couchbase user
# dp-observer depends on this
useradd couchbase && sudo usermod -a -G systemd-journal couchbase && sudo usermod -a -G couchbase ubuntu

# Install and enable ai-gateway
mv /tmp/${PRODUCT}.service /lib/systemd/system/${PRODUCT}.service
mv /tmp/${PRODUCT_PKG_NAME} /home/ubuntu/. && gunzip /home/ubuntu/${PRODUCT_PKG_NAME}
echo ${VERSION}-${BLD_NUM} > /home/ubuntu/version.txt
chown ubuntu:ubuntu /home/ubuntu/${PRODUCT_PKG_NAME%.*}
chmod +x /home/ubuntu/${PRODUCT_PKG_NAME%.*}
chown ubuntu:ubuntu /home/ubuntu/version.txt
sudo -u ubuntu ln -s /home/ubuntu/${PRODUCT_PKG_NAME%.*} /home/ubuntu/${PRODUCT} && chmod 755 /home/ubuntu/${PRODUCT}
systemctl enable ${PRODUCT}.service

# install & enable dp-observer
mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service
mv /tmp/dp-observer.gz /home/ubuntu && gunzip /home/ubuntu/dp-observer.gz
chmod +x /home/ubuntu/dp-observer
chown ubuntu:ubuntu /home/ubuntu/dp-observer
systemctl enable dp-observer.service
