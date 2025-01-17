#!/bin/bash -ex
  sudo mv /tmp/journald.conf /etc/systemd/journald.conf
  sudo chown root:root /etc/systemd/journald.conf
  sudo chmod 755 /etc/systemd/journald.conf
  sudo apt-get update
  # Install dependent packages
  sudo apt-get install -y python3-pip poppler-utils tesseract-ocr
  sudo pip install uv
  sudo apt install -y libreoffice

  # Create couchbase user
  sudo useradd couchbase && sudo usermod -a -G systemd-journal couchbase && sudo usermod -a -G couchbase ubuntu

  # Install and start node exporter
  wget https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/${node_exporter_package}.tar.gz -P /tmp/
  tar xvfz /tmp/${node_exporter_package}.tar.gz -C /home/ubuntu/ --strip-components=1 ${node_exporter_package}/node_exporter
  rm -f /tmp/${node_exporter_package}.tar.gz
  sudo chown ubuntu:ubuntu /home/ubuntu/node_exporter
  sudo mv /tmp/node-exporter.service /lib/systemd/system/node-exporter.service
  sudo systemctl enable node-exporter.service
  # Install and enable process exporter
  wget https://github.com/ncabatoff/process-exporter/releases/download/v${process_exporter_version}/${process_exporter_package}.deb -P /tmp/
  sudo apt install -y /tmp/${process_exporter_package}.deb
  rm /tmp/${process_exporter_package}.deb
  sudo mv /tmp/process-exporter.service /lib/systemd/system/process-exporter.service
  sudo systemctl enable process-exporter.service
  # install and enable observer service
  sudo mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service
  sudo mv /tmp/dp-observer.gz /home/ubuntu/ && sudo gunzip /home/ubuntu/dp-observer.gz
  sudo chmod +x /home/ubuntu/dp-observer && sudo systemctl enable dp-observer.service

  # Install and enable vulcan
  mkdir /home/ubuntu/vulcan & tar xvfz /tmp/vulcan.tar.gz -C /home/ubuntu/vulcan --strip-components=1
  rm -f /tmp/vulcan.tar.gz
  uv venv --python 3.11 --python-preference only-managed
  source .venv/bin/activate
  python -m ensurepip --upgrade --default-pip
  pip install /home/ubuntu/vulcan/vulcan*.whl
  pip install -r /home/ubuntu/vulcan/backend/requirements.txt
  pip install "unstructured[all-docs]==0.16.12"
  pip install python-magic spacy
  pip install pyopenssl --upgrade
  python -m spacy download en_core_web_lg
  sudo mv /tmp/vulcan.service /lib/systemd/system/vulcan.service
  sudo systemctl enable vulcan.service
