variable "product_name" {
  type = string
}
variable "product_version" {
  type = string
}
variable "product_bld_num" {
  type = string
}
variable "ami_name" {
  type = string
}
variable "region" {
  type = string
}
variable "ami_regions" {
  type = list(string)
}
variable "dp_service" {
  type = string
}
variable "ns_server_profile" {
  type = string
}
variable "product_arch" {
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

  // install & enable dp-observer
  setupDPObserver = "sudo mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service && sudo gunzip -c /tmp/dp-observer.gz > /home/ec2-user/dp-observer && sudo chmod +x /home/ec2-user/dp-observer && sudo systemctl enable dp-observer.service"
  dPObserverConfig = var.dp_service != local.dp_backup_service ? local.setupDPObserver : ""

  // configure ns_server profile
  nsServerProfileConfig = "sudo mkdir -p /etc/couchbase.d && sudo bash -c 'echo ${var.ns_server_profile} > /etc/couchbase.d/config_profile' && sudo chmod 755 /etc/couchbase.d/config_profile && sudo chown -R couchbase:couchbase /etc/couchbase.d"

  ami_arch = var.product_arch == "aarch64" ? "arm64" : "x86_64"
  source_ami_name = "amzn2-ami-kernel-5.10-hvm-2.0.*-${local.ami_arch}-gp2"
  instance_type = local.ami_arch == "arm64" ? "t4g.micro" : "t2.micro"
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
  ssh_timeout   = "15m"
  source_ami_filter {
    filters = {
      name                = "${local.source_ami_name}"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }
  tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
    agent       = "${var.agent_sha}"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
    agent       = "${var.agent_sha}"
  }
  ssh_username = "ec2-user"
}

// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.amazon-ebs.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "couchbase-server-enterprise-${var.product_version}-${var.product_bld_num}-linux.${var.product_arch}.rpm"
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
    destination = "/tmp/disable-thp"
    source      = "disable-thp"
  }

  provisioner "file" {
    destination = "/tmp/dp-backup.conf"
    source = "dp-backup.conf"
  }

  provisioner "file" {
    destination = "/tmp/journald.conf"
    source = "journald.conf"
  }

  provisioner "file" {
   destination = "/tmp/iptables-firewall.sh"
   source = "iptables-firewall.sh"
  }

  provisioner "file" {
   destination = "/tmp/dp-firewall.service"
   source = "dp-firewall.service"
  }

  provisioner "file" {
    destination = "/tmp/agent.config"
    source = "shoreline.agent.config"
  }

  provisioner "shell" {
    inline = [
      "sleep 10",
      "sudo mv /tmp/disable-thp /etc/init.d/disable-thp",
      "sudo chmod 755 /etc/init.d/disable-thp",
      "sudo chkconfig --add disable-thp",
      "sudo mv /tmp/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 755 /etc/systemd/journald.conf",
      // Set swappiness to 1 to avoid swapping excessively
      "sudo sh -c 'echo \"vm.swappiness = 0\" >> /etc/sysctl.conf'",
      // Install dependent yum packages:
      //   tzdata: timezone info used by some N1QL functions
      //   dependencies for system commands used by cbcollect_info:
      //     lsof: lsof
      //     shw: lshw
      //     sysstat: iostat, sar, mpstat
      //     net-tools: ifconfig, arp, netstat
      //     numactl: numactl
      //     ntp: ntpdate, ntpq
      "sudo yum install -y nmap-ncat ntp lshw lsof sysstat net-tools numactl tzdata",
      // Create couchbase user
      "sudo useradd couchbase && sudo usermod -a -G systemd-journal couchbase && sudo usermod -a -G couchbase ec2-user",
      // Setup ns_server profile
      "${local.nsServerProfileConfig}",
      "sudo yum install -y /tmp/couchbase-server-enterprise-${var.product_version}-${var.product_bld_num}-linux.${var.product_arch}.rpm",
      "rm /tmp/couchbase-server-enterprise-${var.product_version}-${var.product_bld_num}-linux.${var.product_arch}.rpm",
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
      "sudo wget https://github.com/ncabatoff/process-exporter/releases/download/v${local.process-exporter_version}/${local.process-exporter_package}.rpm -P /tmp/",
      "sudo rpm --install /tmp/${local.process-exporter_package}.rpm",
      "sudo rm /tmp/${local.process-exporter_package}.rpm",
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
      "sudo mv /tmp/iptables-firewall.sh /home/ec2-user",
      "sudo chmod +x /home/ec2-user/iptables-firewall.sh",
      "sudo chown root:root /home/ec2-user/iptables-firewall.sh",
      "sudo systemctl start dp-firewall.service",
      "sudo systemctl enable dp-firewall.service",
      // Add imports directory
      "sudo mkdir -p /home/ec2-user/imports",
      "sudo chown ec2-user:ec2-user /home/ec2-user/imports",
      // Install the Shoreline agent
      "sudo mkdir -p /home/ec2-user/shoreline",
      "sudo mv /tmp/agent.config /home/ec2-user/shoreline",
      "sudo chown -R ec2-user:ec2-user /home/ec2-user/shoreline",
      "pushd /home/ec2-user/shoreline",
      "curl -L 'https://shorelinedownload.blob.core.windows.net/agent/vm_base_install_0.6.4.sh' -o vm_base_install.sh",
      "chmod +x vm_base_install.sh",
      "sudo ./vm_base_install.sh",
      // Shoreline start-up is handled by dp-agent. Docker & containerd will start as dependencies once the Shoreline agent starts
      "sudo systemctl disable shoreline.shoreline.service shoreline.node_exporter.service",
      // Create the Shoreline secrets directory, allowing dp-agent to bootstrap it
      "sudo mkdir -p /var/lib/shoreline/agent/secrets",
      "sudo chown shoreline:shoreline /var/lib/shoreline/agent/secrets",
      // Prevent the agent startup script from printing secrets to the system log
      "sudo sed -i 's/^set -o xtrace/#set -o xtrace/g' /usr/bin/shoreline-agent",
      // Install jq to enable Shoreline users to format and manipulate API output
      "sudo yum install -y jq",
      // Setup Rsyslog conf for dp-backup
      "${local.useDPBackupConf}",
      // Install & configure dp-observer
      "${local.dPObserverConfig}",
      "sudo rm -f /tmp/dp-observer*"
    ]
  }
}
