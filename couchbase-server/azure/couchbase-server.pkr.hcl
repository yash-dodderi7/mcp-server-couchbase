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
variable "ns_server_profile" {
  type = string
}
variable "product_arch" {
  type = string
}
variable "dp_service" {
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
variable "agent_sha" {
  type = string
}

locals {
  dp_backup_service = "dp-backup"
  setupDPBackupRsyslog = "sudo sh -c 'mv /tmp/dp-backup.conf /etc/rsyslog.d/dp-backup.conf && sudo systemctl restart rsyslog'"
  // only inject rsyslog conf for dp-backup
  useDPBackupConf = var.dp_service == local.dp_backup_service ? local.setupDPBackupRsyslog : ""

  // install & enable dp-observer
  setupDPObserver = "sudo mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service && sudo gunzip -c /tmp/dp-observer.gz > /home/ec2-user/dp-observer && sudo chmod +x /home/ec2-user/dp-observer && sudo systemctl enable dp-observer.service"
  dPObserverConfig = var.dp_service != local.dp_backup_service ? local.setupDPObserver : ""

  // configure ns_server profile
  nsServerProfileConfig = can(regex("7.2", var.product_version)) ? "" : "sudo mkdir -p /etc/couchbase.d && sudo bash -c 'echo ${var.ns_server_profile} > /etc/couchbase.d/config_profile' && sudo chmod 755 /etc/couchbase.d/config_profile && sudo chown -R couchbase:couchbase /etc/couchbase.d"

  // server build compiles single linux deb file for Neo and newer.  Ubuntu and Debian packages are merely copies of linux deb file.
  platform = "linux"
  image_sku = "server"
  image_offer = "ubuntu-24_04-lts"

  exporter_arch = var.product_arch
  process-exporter_version = "0.8.3"
  process-exporter_package = "process-exporter_${local.process-exporter_version}_linux_${local.exporter_arch}"
  node_exporter_version = "1.1.2"
  node_exporter_package = "node_exporter-${local.node_exporter_version}.linux-${local.exporter_arch}"
  pushgateway_version = "1.11.0"
  pushgateway_package = "pushgateway-${local.pushgateway_version}.linux-${local.exporter_arch}"
}

// Azure machine image Builder
source "azure-arm" "cc" {
  azure_tags = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    product_version      = "${var.product_version}"
    image_version        = "${var.image_version}"
    agent                = "${var.agent_sha}"
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

// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.azure-arm.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "${var.product_pkg_name}"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "agents/${var.product_arch}/${var.dp_service}.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "${var.dp_service}.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "pushgateway.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "agents/${var.product_arch}/dp-observer.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "dp-observer.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "node-exporter.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "process-exporter.service"
  }

  provisioner "file" {
    destination = "/tmp/disable-thp.service"
    source      = "disable-thp.service"
  }

  provisioner "file" {
    destination = "/tmp/dp-backup.conf"
    source      = "dp-backup.conf"
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
    destination = "/tmp/dp-firewall.service"
    source      = "dp-firewall.service"
  }

  provisioner "shell" {
    inline = [
      "sleep 10",
      // create new group and allow users to sudo without a password
      "echo \"ec2-user ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/dpapps",
      // disable transparent huge pages and setup journald
      "sudo mv /tmp/disable-thp.service /lib/systemd/system/disable-thp.service",
      "sudo chmod 755 /lib/systemd/system/disable-thp.service",
      "sudo systemctl start disable-thp.service",
      "sudo systemctl enable disable-thp.service",
      "sudo mv /tmp/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 755 /etc/systemd/journald.conf",
      // Set swappiness to 1 to avoid swapping excessively
      "sudo sh -c 'echo \"vm.swappiness = 0\" >> /etc/sysctl.conf'",
      "sudo sysctl vm.swappiness=0",
      // Install dependent packages:
      //   tzdata: timezone info used by some N1QL functions
      //   dependencies for system commands used by cbcollect_info:
      //     lsof: lsof
      //     shw: lshw
      //     sysstat: iostat, sar, mpstat
      //     net-tools: ifconfig, arp, netstat
      //     numactl: numactl
      //     ntp: ntpdate, ntpq
      "sudo apt update",
      "sudo apt install -y nmap ncat ntp lshw lsof sysstat net-tools numactl tzdata wget rsync jq",
      // Create couchbase server
      "sudo useradd couchbase && sudo usermod -a -G systemd-journal couchbase && sudo usermod -a -G couchbase ec2-user",
      // Setup ns_server profile
      "${local.nsServerProfileConfig}",
      "export INSTALL_DONT_START_SERVER=1",
      "sudo -E apt install -y /tmp/${var.product_pkg_name}",
      "sudo rm /tmp/${var.product_pkg_name}",
      // Setup the directory for the TLS certificate and key
      "sudo mkdir -p /opt/couchbase/var/lib/couchbase/inbox/CA/",
      "sudo touch /opt/couchbase/var/lib/couchbase/inbox/CA/ca.pem",
      "sudo touch /opt/couchbase/var/lib/couchbase/inbox/chain.pem",
      "sudo touch /opt/couchbase/var/lib/couchbase/inbox/pkey.key",
      "sudo chown -R ec2-user:couchbase /opt/couchbase/var/lib/couchbase/inbox/",
      "sudo chmod 0640 /opt/couchbase/var/lib/couchbase/inbox/CA/ca.pem",
      "sudo chmod 0640 /opt/couchbase/var/lib/couchbase/inbox/chain.pem",
      "sudo chmod 0640 /opt/couchbase/var/lib/couchbase/inbox/pkey.key",
      "sudo systemctl disable couchbase-server",
      // Install and start node exporter
      "sudo wget https://github.com/prometheus/node_exporter/releases/download/v${local.node_exporter_version}/${local.node_exporter_package}.tar.gz -P /tmp/",
      "sudo tar xvfz /tmp/${local.node_exporter_package}.tar.gz -C /home/ec2-user/ --strip-components=1 ${local.node_exporter_package}/node_exporter",
      "sudo rm -f /tmp/${local.node_exporter_package}.tar.gz",
      "sudo chown ec2-user:ec2-user /home/ec2-user/node_exporter",
      "sudo mv /tmp/node-exporter.service /lib/systemd/system/node-exporter.service",
      "sudo systemctl enable node-exporter.service",
      // Install and enable process exporter
      "sudo wget https://github.com/ncabatoff/process-exporter/releases/download/v${local.process-exporter_version}/${local.process-exporter_package}.deb -P /tmp/",
      "sudo apt install -y /tmp/${local.process-exporter_package}.deb",
      "sudo rm /tmp/${local.process-exporter_package}.deb",
      "sudo mv /tmp/process-exporter.service /lib/systemd/system/process-exporter.service",
      "sudo systemctl enable process-exporter.service",
      // Install pushgateway - do not enable
      "sudo wget https://github.com/prometheus/pushgateway/releases/download/v${local.pushgateway_version}/${local.pushgateway_package}.tar.gz -P /tmp/",
      "sudo tar xvfz /tmp/${local.pushgateway_package}.tar.gz -C /home/ec2-user/ --strip-components=1 ${local.pushgateway_package}/pushgateway",
      "sudo rm -f /tmp/${local.pushgateway_package}.tar.gz",
      "sudo chown ec2-user:ec2-user /home/ec2-user/pushgateway",
      "sudo mv /tmp/pushgateway.service /lib/systemd/system/pushgateway.service",
      // Install and enable dp-agent
      "sudo mv /tmp/${var.dp_service}.service /lib/systemd/system/${var.dp_service}.service",
      "sudo mv /tmp/${var.dp_service}.gz /home/ec2-user",
      "sudo gunzip /home/ec2-user/${var.dp_service}.gz",
      "sudo chmod +x /home/ec2-user/${var.dp_service}",
      "sudo systemctl enable ${var.dp_service}.service",
      // Install firewall service
      "sudo mv /tmp/dp-firewall.service /lib/systemd/system/dp-firewall.service",
      "sudo mv /tmp/iptables-firewall.sh /home/ec2-user",
      "sudo chmod +x /home/ec2-user/iptables-firewall.sh",
      "sudo chown root:root /home/ec2-user/iptables-firewall.sh",
      "sudo systemctl start dp-firewall.service",
      "sudo systemctl enable dp-firewall.service",
      // Add imports directory
      "sudo mkdir -p /home/ec2-user/imports",
      "sudo chown ec2-user:ec2-user /home/ec2-user/imports",
      // Setup Rsyslog conf for dp-backup
      "${local.useDPBackupConf}",
      // Install & configure dp-observer
      "${local.dPObserverConfig}",
      "sudo rm -f /tmp/dp-observer*"
    ]
  }
}
