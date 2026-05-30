packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.10"
      source = "github.com/hashicorp/amazon"
    }
  }
}
variable "product_pkg_name" {
  type = string
}
variable "product_version" {
  type = string
}
variable "product_bld_num" {
  type = string
}
variable "product_arch" {
  type = string
}
variable "ami_name" {
  type = string
}
variable "ami_regions" {
  type = list(string)
}
variable "region" {
  type = string
}

locals {
  dp_service = "sgw-agent"
  ami_arch = var.product_arch == "aarch64" ? "arm64" : "amd64"
  //source_ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_arch}-server-*"
  source_ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_arch}-server-20260515"
  instance_type = local.ami_arch == "arm64" ? "t4g.micro" : "t3.micro"
  exporter_arch = var.product_arch == "aarch64" ? "arm64" : "amd64"
  process-exporter_version = "0.7.5"
  process-exporter_package = "process-exporter_${local.process-exporter_version}_linux_${local.exporter_arch}"
  node_exporter_version = "1.1.2"
  node_exporter_package = "node_exporter-${local.node_exporter_version}.linux-${local.exporter_arch}"
}

source "amazon-ebs" "cc" {
  ami_name      = "${var.ami_name}"
  ami_regions   = "${var.ami_regions}"
  instance_type = "${local.instance_type}"
  region        = "${var.region}"
  source_ami_filter {
    filters = {
      name                = "${local.source_ami_name}"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
  tags = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    product_version      = "${var.product_version}"
    version              = "${var.product_version}-${var.product_bld_num}"
  }
  snapshot_tags = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    product_version      = "${var.product_version}"
    persion              = "${var.product_version}-${var.product_bld_num}"
  }
  ssh_username = "ubuntu"
}

# a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.amazon-ebs.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "${var.product_pkg_name}"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "agents/${var.product_arch}/${local.dp_service}.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "${local.dp_service}.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "node-exporter.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "fluent-bit.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "audit-fluent-bit.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "agents/${var.product_arch}/sgw-observer.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "sgw-observer.service"
  }

  provisioner "file" {
    destination = "/tmp/journald.conf"
    source      = "journald.conf"
  }

  provisioner "file" {
    destination = "/tmp/iptables-firewall.sh"
    source      = "iptables-firewall.sh"
  }

  provisioner "file" {
    destination = "/tmp/sgw-firewall.service"
    source      = "sgw-firewall.service"
  }

  provisioner "shell" {
    inline = [
      "sleep 10",
      // create new group and allow users to sudo without a password
      "sudo useradd -m -s /bin/bash ec2-user",
      "echo \"ec2-user ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/dpapps",
      "sudo mv /tmp/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 755 /etc/systemd/journald.conf",
      // Set swappiness to 1 to avoid swapping excessively
      "sudo sh -c 'echo \"vm.swappiness = 0\" >> /etc/sysctl.conf'",
      "sudo sysctl vm.swappiness=0",
      // Install dependent packages:
      "sudo apt update",
      "sudo apt install -y bzip2 curl gpg wget rsync",
      // run unattended-upgrade to apply kernel and security patches
      // then disable it so that it so that it doesn't cause unexpected side effect in production
      "sudo unattended-upgrade",
      "sudo systemctl disable --now unattended-upgrades.service",
      "sudo sed -i 's/^APT::Periodic::Unattended-Upgrade\\s*\"\\?1\"\\?;/APT::Periodic::Unattended-Upgrade \"0\";/' /etc/apt/apt.conf.d/20auto-upgrades",

      "sudo apt install -y /tmp/${var.product_pkg_name}",
      "sudo rm /tmp/${var.product_pkg_name}",

      "sudo chown -R sync_gateway:sync_gateway /home/sync_gateway",


      // Add sync_gateway user to ec2-user group, so it can read files created by ec2-user
      // Add sync_gateway user to systemd-journal group
      "sudo usermod -a -G ec2-user sync_gateway && sudo usermod -a -G systemd-journal sync_gateway",

      "sudo usermod -a -G sync_gateway ec2-user",
      "sudo usermod -a -G systemd-journal ec2-user",
      "sudo chmod 770 /home/sync_gateway/",

      // Remove the default startup config.
      "sudo rm -rf /home/sync_gateway/sync_gateway.json",
      // Replace the config env in the systemd file with the path of the
      // bootstrap config which will be created by the agent.
      "sudo sed -i -e 's@CONFIG=/home/sync_gateway/sync_gateway.json@CONFIG=/dev/shm/sync_gateway_bootstrap.json@g' /usr/lib/systemd/system/sync_gateway.service",

      // Install and start node exporter
      "sudo wget https://github.com/prometheus/node_exporter/releases/download/v${local.node_exporter_version}/${local.node_exporter_package}.tar.gz -P /tmp/",
      "sudo tar xvfz /tmp/${local.node_exporter_package}.tar.gz -C /home/ec2-user/ --strip-components=1 ${local.node_exporter_package}/node_exporter",
      "sudo rm -f /tmp/${local.node_exporter_package}.tar.gz",
      "sudo chown ec2-user:ec2-user /home/ec2-user/node_exporter",
      "sudo mv /tmp/node-exporter.service /lib/systemd/system/node-exporter.service",
      "sudo systemctl enable node-exporter.service",
      // Install and enable ${local.dp_service}
      "sudo mv /tmp/${local.dp_service}.service /lib/systemd/system/${local.dp_service}.service",
      "sudo mv /tmp/${local.dp_service}.gz /home/ec2-user",
      "sudo gunzip /home/ec2-user/${local.dp_service}.gz",
      "sudo chmod +x /home/ec2-user/${local.dp_service}",
      "sudo systemctl enable ${local.dp_service}.service",
      

      "sudo mv /tmp/sgw-observer.service /lib/systemd/system/sgw-observer.service",
      "sudo gunzip -c /tmp/sgw-observer.gz > /tmp/sgw-observer",
      "sudo mv /tmp/sgw-observer /home/ec2-user/sgw-observer",
      "sudo chmod +x /home/ec2-user/sgw-observer",
      "sudo systemctl enable sgw-observer.service",
      "sudo rm -f /tmp/sgw-observer*",
      // Install firewall service
      "sudo mv /tmp/sgw-firewall.service /lib/systemd/system/sgw-firewall.service",
      "sudo mv /tmp/iptables-firewall.sh /home/ec2-user",
      "sudo chmod +x /home/ec2-user/iptables-firewall.sh",
      "sudo chown root:root /home/ec2-user/iptables-firewall.sh",
      "sudo systemctl start sgw-firewall.service",
      "sudo systemctl enable sgw-firewall.service",
      // Install fluent-bit
      "curl -fsSL https://packages.fluentbit.io/fluentbit.key | gpg --dearmor | sudo tee /usr/share/keyrings/fluentbit-keyring.gpg > /dev/null",
      "echo \"deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/ubuntu/noble noble main\" | sudo tee -a /etc/apt/sources.list",
      "sudo apt-get update",
      "sudo apt-get install -y fluent-bit",
      "sudo mv /tmp/fluent-bit.service /usr/lib/systemd/system/fluent-bit.service",
      "sudo mv /tmp/audit-fluent-bit.service /usr/lib/systemd/system/audit-fluent-bit.service",
    ]
  }
}
