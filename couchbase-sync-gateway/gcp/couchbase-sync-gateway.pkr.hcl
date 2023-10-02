packer {
  required_plugins {
    windows-update = {
      version = "0.14.1"
      source  = "github.com/rgl/windows-update"
    }
  }
}

variable "product_name" {
  type = string
}
variable "product_version" {
  type = string
}
variable "product_bld_num" {
  type = string
}
variable "image_name" {
  type = string
}
variable "image_version" {
  type = string
}
variable "zone" {
  type = string
}

variable "project_id" {
  type = string
}

variable "network_id" {
  type = string
}

variable "access_token" {
  type = string
}

locals {
  source_image = "ubuntu-2004-focal-v20220419" 
  dp_service = "sgw-agent"
  product_arch = "x86_64"
  exporter_arch = "amd64"
  node_exporter_version = "1.1.2"
  node_exporter_package = "node_exporter-${local.node_exporter_version}.linux-${local.exporter_arch}"
}

source "googlecompute" "cc" {
  access_token = "${var.access_token}"
  project_id = "${var.project_id}"
  source_image = "${local.source_image}"
  zone = "${var.zone}"
  // both network and subnetwork name are identicial.
  network = "${var.network_id}"
  subnetwork = "${var.network_id}"
  machine_type = "n2-standard-2"

  ssh_username = "ec2-user"
  image_name = "${var.image_name}"

  image_labels = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${local.product_arch}"
    version              = "${var.image_version}"
    build                = "${var.product_bld_num}"
  }
}

# a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.googlecompute.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "couchbase-sync-gateway-enterprise_${var.product_version}-${var.product_bld_num}_${local.product_arch}.deb"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "agents/${local.product_arch}/${local.dp_service}.gz"
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
      "echo \"ec2-user ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/dpapps",
      "sudo mv /tmp/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 755 /etc/systemd/journald.conf",
      // Set swappiness to 1 to avoid swapping excessively
      "sudo sh -c 'echo \"vm.swappiness = 0\" >> /etc/sysctl.conf'",
      "sudo sysctl vm.swappiness=0",
      // Install dependent packages:
      "sudo apt update",
      "sudo apt install -y bzip2 wget rsync",
      "sudo apt install -y /tmp/couchbase-sync-gateway-enterprise_${var.product_version}-${var.product_bld_num}_${local.product_arch}.deb",
      "sudo rm /tmp/couchbase-sync-gateway-enterprise_${var.product_version}-${var.product_bld_num}_${local.product_arch}.deb",
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
      // Install firewall service
      "sudo mv /tmp/sgw-firewall.service /lib/systemd/system/sgw-firewall.service",
      "sudo mv /tmp/iptables-firewall.sh /usr/local/bin",
      "sudo chmod +x /usr/local/bin/iptables-firewall.sh",
      "sudo chown root:root /usr/local/bin/iptables-firewall.sh",
      "sudo systemctl start sgw-firewall.service",
      "sudo systemctl enable sgw-firewall.service",
      // Add sync_gateway user to ec2-user group, so it can read files created by ec2-user
      "sudo usermod -a -G ec2-user sync_gateway",
      // Install fluent-bit
      "curl https://packages.fluentbit.io/fluentbit.key | gpg --dearmor | sudo tee /usr/share/keyrings/fluentbit-keyring.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/ubuntu/focal focal main\" | sudo tee -a /etc/apt/sources.list",
      "sudo apt-get update",
      "sudo apt-get install -y fluent-bit",
      "sudo mv /tmp/fluent-bit.service /usr/lib/systemd/system/fluent-bit.service",
    ]
  }
}
