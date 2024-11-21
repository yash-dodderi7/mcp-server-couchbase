#!/bin/bash -ex
  sudo mv /tmp/journald.conf /etc/systemd/journald.conf
  sudo chown root:root /etc/systemd/journald.conf
  sudo chmod 755 /etc/systemd/journald.conf
  sudo apt-get update
  # Install dependent packages
  sudo apt-get install -y python3-pip poppler-utils tesseract-ocr
  sudo pip install uv
  sudo apt install -y libreoffice
  # Install and enable vulcan
  mkdir /home/ubuntu/vulcan & tar xvfz /tmp/vulcan.tar.gz -C /home/ubuntu/vulcan --strip-components=1
  rm -f /tmp/vulcan.tar.gz
  uv venv --python 3.11 --python-preference only-managed
  source .venv/bin/activate
  python -m ensurepip --upgrade --default-pip
  pip install /home/ubuntu/vulcan/vulcan*.whl
  pip install -r /home/ubuntu/vulcan/backend/requirements.txt
  pip install unstructured[all-docs]
  pip install python-magic spacy
  pip install pyopenssl --upgrade
  python -m spacy download en_core_web_lg
  sudo mv /tmp/vulcan.service /lib/systemd/system/vulcan.service
  sudo systemctl enable vulcan.service
