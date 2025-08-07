packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.0.0"
      source = "github.com/hashicorp/googlecompute"
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
variable "image_name" {
  type = string
}
variable "image_version" {
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

variable "agent_sha" {
  type = string
}

locals {
  dp_backup_service = "dp-backup"
  setupDPBackupRsyslog = "sudo sh -c 'mv /tmp/dp-backup.conf /etc/rsyslog.d/dp-backup.conf && sudo systemctl restart rsyslog'"
  // only inject rsyslog conf for dp-backup
  useDPBackupConf = var.dp_service == local.dp_backup_service ? local.setupDPBackupRsyslog : ""

  // couchbase-server.service or enterprise-analytics.service
  product_service = var.ns_server_profile == "analytics_provisioned" ? "enterprise-analytics" : "couchbase-server"

  // install & enable dp-observer
  setupDPObserver = "sudo mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service && sudo gunzip -c /tmp/dp-observer.gz > /home/ec2-user/dp-observer && sudo chmod +x /home/ec2-user/dp-observer && sudo systemctl enable dp-observer.service"
  dPObserverConfig = var.dp_service != local.dp_backup_service ? local.setupDPObserver : ""

  // configure ns_server profile
  nsServerProfileConfig = local.product_service == "enterprise-analytics" ? "" : can(regex("7.2", var.product_version)) ? "" : "sudo mkdir -p /etc/couchbase.d && sudo bash -c 'echo ${var.ns_server_profile} > /etc/couchbase.d/config_profile' && sudo chmod 755 /etc/couchbase.d/config_profile && sudo chown -R couchbase:couchbase /etc/couchbase.d"


  // arm64 and amd64 specific settings
  //   pd-standard is the default.  It is not compatible with arm64
  //   arm64 is currently not available in us-central1-a
  platform = "linux"
  disk_type = var.product_arch == "amd64" ? "pd-standard" : "hyperdisk-balanced"
  source_image_family = var.product_arch == "amd64" ? "ubuntu-2404-lts-amd64" : "ubuntu-2404-lts-arm64"
  machine_type = var.product_arch == "amd64" ? "n2-standard-2" : "c4a-standard-1"
  zone = var.product_arch == "amd64" ? "us-central1-a" : "us-east4-b"

  exporter_arch = var.product_arch
  process-exporter_version = "0.8.3"
  process-exporter_package = "process-exporter_${local.process-exporter_version}_linux_${local.exporter_arch}"
  node_exporter_version = "1.1.2"
  node_exporter_package = "node_exporter-${local.node_exporter_version}.linux-${local.exporter_arch}"
  pushgateway_version = "1.11.0"
  pushgateway_package = "pushgateway-${local.pushgateway_version}.linux-${local.exporter_arch}"
}

source "googlecompute" "cc" {
  access_token = "${var.access_token}"
  project_id = "${var.project_id}"
  machine_type = "${local.machine_type}"
  source_image_family = "${local.source_image_family}"
  zone = "${local.zone}"
  disk_type = "${local.disk_type}"
  disk_size = 10
  // both network and subnetwork name are identicial.
  network = "${var.network_id}"
  subnetwork = "${var.network_id}"

  ssh_username = "ec2-user"
  image_name = "${var.image_name}"

  image_labels = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    version              = "${var.image_version}"
    build                = "${var.product_bld_num}"
    agent                = "${var.agent_sha}"
  }
}

// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.googlecompute.cc"]

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
    destination = "/tmp/"
    source      = "pushgateway.service"
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
      //MB-57636 configure keepalive settings
      "sudo sh -c 'echo net.ipv4.tcp_keepalive_time=480 >> /etc/sysctl.conf'",
      "sudo sh -c 'echo net.ipv4.tcp_keepalive_intvl=75 >> /etc/sysctl.conf'",
      "sudo sh -c 'echo net.ipv4.tcp_keepalive_probes=9 >> /etc/sysctl.conf'",
      "sudo sysctl -w net.ipv4.tcp_keepalive_time=480 net.ipv4.tcp_keepalive_intvl=75 net.ipv4.tcp_keepalive_probes=9",
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
      // run unattended-upgrade to apply kernel and security patches
      // then disable it so that it so that it doesn't cause unexpected side effect in production
      "sudo unattended-upgrade",
      "sudo systemctl disable --now unattended-upgrades.service",
      "sudo sed -i 's/^APT::Periodic::Unattended-Upgrade\\s*\"\\?1\"\\?;/APT::Periodic::Unattended-Upgrade \"0\";/' /etc/apt/apt.conf.d/20auto-upgrades",

      // Create couchbase user
      "sudo useradd couchbase && sudo usermod -a -G systemd-journal couchbase && sudo usermod -a -G couchbase ec2-user",
      // Setup ns_server profile
      "${local.nsServerProfileConfig}",
      "export INSTALL_DONT_START_SERVER=1",
      "sudo -E apt install -y /tmp/${var.product_pkg_name}",
      "sudo rm /tmp/${var.product_pkg_name}",
      // enterprise-analytics is installed under /opt/enterprise-analytics
      // couchbase-server and couchbase-columnar are installed under /opt/couchbase
      "if [ ${local.product_service} = \"enterprise-analytics\" ]; then BASE_DIR=\"/opt/${local.product_service}\"; else BASE_DIR=\"/opt/couchbase\"; fi",
      // Setup the directory for the TLS certificate and key
      "sudo mkdir -p $${BASE_DIR}/var/lib/couchbase/inbox/CA/",
      "sudo touch $${BASE_DIR}/var/lib/couchbase/inbox/CA/ca.pem",
      "sudo touch $${BASE_DIR}/var/lib/couchbase/inbox/chain.pem",
      "sudo touch $${BASE_DIR}/var/lib/couchbase/inbox/pkey.key",
      "sudo chown -R ec2-user:couchbase $${BASE_DIR}/var/lib/couchbase/inbox/",
      "sudo chmod 0640 $${BASE_DIR}/var/lib/couchbase/inbox/CA/ca.pem",
      "sudo chmod 0640 $${BASE_DIR}/var/lib/couchbase/inbox/chain.pem",
      "sudo chmod 0640 $${BASE_DIR}/var/lib/couchbase/inbox/pkey.key",
      // Configure systemd service with cgroup delegation
      // This applies to couchbase-server 8.0.0 and above.
      // create-provisioned-cgroups.sh only exists in 8.0 and above
      // If this file doesn't exist, we skip changing service file
      "if [ -f $${BASE_DIR}/bin/create-provisioned-cgroups.sh ]; then",
      "  SERVICE_FILE=\"/usr/lib/systemd/system/${local.product_service}.service\"",
      "  CGROUP_PATH=\"/sys/fs/cgroup/system.slice/${local.product_service}.service/\"",
      "  CGROUP_SCRIPT=\"$${BASE_DIR}/bin/create-provisioned-cgroups.sh\"",
      "  # Add systemd cgroup delegation settings",
      "  sudo sed -i '/\\[Service\\]/a Delegate=yes' \"$${SERVICE_FILE}\"",
      "  sudo sed -i \"/Delegate=yes/a ExecStartPre=$${CGROUP_SCRIPT} '$${CGROUP_PATH}'\" \"$${SERVICE_FILE}\"",
      "  sudo sed -i '/ExecStartPre=/a # this is where babysitter and all extraneous goport procs will end up' \"$${SERVICE_FILE}\"",
      "  sudo sed -i '/# this is where babysitter and all extraneous goport procs will end up/a DelegateSubgroup=babysitter' \"$${SERVICE_FILE}\"",
      "  sudo systemctl daemon-reload",
      "fi",
      "sudo systemctl disable ${local.product_service}",
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
