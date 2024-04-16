packer {
  required_plugins {
    windows-update = {
      version = "0.14.1"
      source  = "github.com/rgl/windows-update"
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
variable "subscription_id" {
  type = string
}
variable "client_id" {
  type = string
}
variable "client_secret" {
  type = string
}
variable "resource_group" {
  type = string
}
variable "image_gallery" {
  type = string
}
variable "image_definition" {
  type = string
}
variable "image_name" {
  type = string
}
variable "image_version" {
  type = string
}
variable "region" {
  type = string
}
variable "replication_regions" {
  type = list(string)
}

locals {
  platform = "ubuntu20.04"
  image_sku = "20_04-lts-gen2"
  image_offer = "0001-com-ubuntu-server-focal"

  dp_service = "sgw-agent"
  product_arch = "x86_64"
  exporter_arch = "amd64"
  node_exporter_version = "1.1.2"
  node_exporter_package = "node_exporter-${local.node_exporter_version}.linux-${local.exporter_arch}"

   // install & enable sgw-observer
  sgwObserverConfig = "sudo mv /tmp/sgw-observer.service /lib/systemd/system/sgw-observer.service && sudo gunzip -c /tmp/sgw-observer.gz > /home/ec2-user/sgw-observer && sudo chmod +x /home/ec2-user/sgw-observer && sudo systemctl enable sgw-observer.service"
}

# Azure machine image Builder
source "azure-arm" "cc" {
  azure_tags = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${local.product_arch}"
    product_version      = "${var.product_version}"
    image_version        = "${var.image_version}"
  }

  shared_image_gallery_destination {
    subscription         = "${var.subscription_id}"
    resource_group       = "${var.resource_group}"
    gallery_name         = "${var.image_gallery}"
    image_name           = "${var.image_definition}"
    storage_account_type = "Standard_LRS"
    image_version        = "${var.image_version}"
    replication_regions  = "${var.replication_regions}"
  }

  client_id                          = "${var.client_id}"
  client_secret                      = "${var.client_secret}"
  image_offer                        = "${local.image_offer}"
  image_publisher                    = "canonical"
  image_sku                          = "${local.image_sku}"
  managed_image_name                 = "${var.image_name}"
  managed_image_resource_group_name  = "${var.resource_group}"
  managed_image_storage_account_type = "Standard_LRS"
  os_type                            = "Linux"
  location                           = "${var.region}"
  subscription_id                    = "${var.subscription_id}"
  vm_size                            = "Standard_D2s_v3"
  ssh_username                       = "ec2-user"
}

# a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.azure-arm.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "${var.product_pkg_name}"
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
    destination = "/tmp/"
    source      = "agents/${local.product_arch}/sgw-observer.gz"
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
      "sudo apt install -y /tmp/${var.product_pkg_name}",
      "sudo rm /tmp/${var.product_pkg_name}",
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

      // Install & configure sgw-observer
      "${local.sgwObserverConfig}",
      "sudo rm -f /tmp/sgw-observer*",

      // Install firewall service
      "sudo mv /tmp/sgw-firewall.service /lib/systemd/system/sgw-firewall.service",
      "sudo mv /tmp/iptables-firewall.sh /usr/local/bin",
      "sudo chmod +x /usr/local/bin/iptables-firewall.sh",
      "sudo chown root:root /usr/local/bin/iptables-firewall.sh",
      "sudo systemctl start sgw-firewall.service",
      "sudo systemctl enable sgw-firewall.service",
      // Add sync_gateway user to systemd-journal group
      "sudo usermod -a -G ec2-user sync_gateway && sudo usermod -a -G systemd-journal sync_gateway",
      // Install fluent-bit
      "curl https://packages.fluentbit.io/fluentbit.key | gpg --dearmor | sudo tee /usr/share/keyrings/fluentbit-keyring.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/ubuntu/focal focal main\" | sudo tee -a /etc/apt/sources.list",
      "sudo apt-get update",
      "sudo apt-get install -y fluent-bit",
      "sudo mv /tmp/fluent-bit.service /usr/lib/systemd/system/fluent-bit.service",
    ]
  }
}
