packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.0.0"
      source = "github.com/hashicorp/googlecompute"
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
variable "enableServerless" {
  type = string
}
variable "product_arch" {
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

variable "dp_service" {
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
  dp_backup_service = "dp-backup"
  setupDPBackupRsyslog = "sudo sh -c 'mv /tmp/dp-backup.conf /etc/rsyslog.d/dp-backup.conf && sudo systemctl restart rsyslog'"
  // only inject rsyslog conf for dp-backup
  useDPBackupConf = var.dp_service == local.dp_backup_service ? local.setupDPBackupRsyslog : ""

  // install & enable dp-observer
  setupDPObserver = "sudo mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service && sudo gunzip -c /tmp/dp-observer.gz > /home/ec2-user/dp-observer && sudo chmod +x /home/ec2-user/dp-observer"
  dPObserverConfig = var.dp_service != local.dp_backup_service ? local.setupDPObserver : ""

  setupServerless = "sudo mkdir -p /etc/couchbase.d && sudo bash -c 'echo serverless > /etc/couchbase.d/config_profile' && sudo chmod 755 /etc/couchbase.d/config_profile && sudo chown -R couchbase:couchbase /etc/couchbase.d"
  enableServerless = "true"
  serverlessConfig = var.enableServerless == local.enableServerless ? local.setupServerless : ""

  // server build compiles single linux deb file for Neo and newer.  Ubuntu and Debian packages are merely copies of linux deb file.
  platform = "linux"
  source_image = "ubuntu-2004-focal-v20220419"

  exporter_arch = var.product_arch
  process-exporter_version = "0.7.5"
  process-exporter_package = "process-exporter_${local.process-exporter_version}_linux_${local.exporter_arch}"
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
    arch                 = "${var.product_arch}"
    version              = "${var.image_version}"
    build                = "${var.product_bld_num}"
  }
}

// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.googlecompute.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "couchbase-server-enterprise_${var.product_version}-${var.product_bld_num}-${local.platform}_${var.product_arch}.deb"
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

  provisioner "file" {
    destination = "/tmp/agent.config"
    source = "shoreline.agent.config"
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
      "sudo apt install -y nmap ncat ntp lshw lsof sysstat net-tools numactl tzdata wget rsync",
      // Enable serverless
      "${local.serverlessConfig}",
      "sudo apt install -y /tmp/couchbase-server-enterprise_${var.product_version}-${var.product_bld_num}-${local.platform}_${var.product_arch}.deb",
      "sudo rm /tmp/couchbase-server-enterprise_${var.product_version}-${var.product_bld_num}-${local.platform}_${var.product_arch}.deb",
      // Setup the directory for the TLS certificate and key
      "sudo usermod -a -G couchbase ec2-user",
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
      // Install and enable dp-agent
      "sudo mv /tmp/${var.dp_service}.service /lib/systemd/system/${var.dp_service}.service",
      "sudo mv /tmp/${var.dp_service}.gz /home/ec2-user",
      "sudo gunzip /home/ec2-user/${var.dp_service}.gz",
      "sudo chmod +x /home/ec2-user/${var.dp_service}",
      "sudo systemctl enable ${var.dp_service}.service",
      // Install firewall service
      "sudo mv /tmp/dp-firewall.service /lib/systemd/system/dp-firewall.service",
      "sudo mv /tmp/iptables-firewall.sh /usr/local/bin",
      "sudo chmod +x /usr/local/bin/iptables-firewall.sh",
      "sudo chown root:root /usr/local/bin/iptables-firewall.sh",
      "sudo systemctl start dp-firewall.service",
      "sudo systemctl enable dp-firewall.service",
      // Add imports directory
      "sudo mkdir -p /home/ec2-user/imports",
      "sudo chown ec2-user:ec2-user /home/ec2-user/imports",
      // Setup Rsyslog conf for dp-backup
      "${local.useDPBackupConf}",
      // Install & configure dp-observer
      "${local.dPObserverConfig}",
      "sudo rm -f /tmp/dp-observer*",
      // Install the Shoreline agent
      "sudo mkdir -p /home/ec2-user/shoreline",
      "sudo mv /tmp/agent.config /home/ec2-user/shoreline",
      "sudo chown -R ec2-user:ec2-user /home/ec2-user/shoreline",
      "cd /home/ec2-user/shoreline",
      "curl -L 'https://shorelinedownload.blob.core.windows.net/agent/vm_base_install_0.6.4.sh' -o vm_base_install.sh",
      "chmod +x vm_base_install.sh",
      "sudo ./vm_base_install.sh",
      // Shoreline start-up is handled by dp-agent. Docker & containerd will start as dependencies once the Shoreline agent starts
      "sudo systemctl disable shoreline.service node_exporter.service",
      // Create the Shoreline secrets directory, allowing dp-agent to bootstrap it
      "sudo mkdir -p /var/lib/shoreline/agent/secrets",
      "sudo chown shoreline:shoreline /var/lib/shoreline/agent/secrets",
      // Install jq to enable Shoreline users to format and manipulate API output
      "sudo apt install -y jq"
    ]
  }
}
