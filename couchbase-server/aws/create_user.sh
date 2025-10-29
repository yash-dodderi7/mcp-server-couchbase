#!/bin/bash
set -e

# Create ec2-user
sudo useradd -m -s /bin/bash ec2-user
sudo mkdir -p /home/ec2-user/.ssh
sudo chown -R ec2-user:ec2-user /home/ec2-user/.ssh
sudo chmod 700 /home/ec2-user/.ssh
