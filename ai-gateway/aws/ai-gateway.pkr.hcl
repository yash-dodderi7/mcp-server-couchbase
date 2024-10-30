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
variable "product_arch" {
  type = string
}
variable "agent_sha" {
  type = string
}

locals {
  product = "ai-gateway"
  product_pkg_name = "${local.product}-${var.product_version}-${var.product_bld_num}-linux-${var.product_arch}"
  ami_arch = var.product_arch == "amd64" ? "x86_64" : "arm64"
  source_ami_name = "amzn2-ami-kernel-5.10-hvm-2.0.*-${local.ami_arch}-gp2"

  instance_type = var.product_arch == "arm64" ? "t4g.micro" : "t2.micro"
  exporter_arch = var.product_arch
  process-exporter_version = "0.8.3"
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
    source      = "${local.product_pkg_name}.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "agents/${var.product_arch}/dp-agent.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "dp-agent.service"
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
   destination = "/tmp/${local.product}.service"
   source = "${local.product}.service"
  }

  provisioner "shell" {
    inline = [
      "sleep 10",
      "sudo mv /tmp/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 755 /etc/systemd/journald.conf",
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
      // Create couchbase user
      "sudo useradd couchbase && sudo usermod -a -G systemd-journal couchbase && sudo usermod -a -G couchbase ec2-user",
      // Install and enable ai-gateway
      "sudo mv /tmp/${local.product}.service /lib/systemd/system/${local.product}.service",
      "sudo mv /tmp/${local.product_pkg_name}.gz /home/ec2-user",
      "sudo gunzip /home/ec2-user/${local.product_pkg_name}.gz",
      "sudo chmod +x /home/ec2-user/${local.product_pkg_name}",
      "sudo ln -s /home/ec2-user/${local.product_pkg_name} /home/ec2-user/${local.product}",
      "sudo systemctl enable ${local.product}.service",
      // Install firewall service
      "sudo mv /tmp/dp-firewall.service /lib/systemd/system/dp-firewall.service",
      "sudo mv /tmp/iptables-firewall.sh /home/ec2-user",
      "sudo chmod +x /home/ec2-user/iptables-firewall.sh",
      "sudo chown root:root /home/ec2-user/iptables-firewall.sh",
      "sudo systemctl start dp-firewall.service",
      "sudo systemctl enable dp-firewall.service",
      // Install and enable dp-agent
      "sudo mv /tmp/dp-agent.service /lib/systemd/system/dp-agent.service",
      "sudo mv /tmp/dp-agent.gz /home/ec2-user && sudo gunzip /home/ec2-user/dp-agent.gz",
      "sudo chmod +x /home/ec2-user/dp-agent && sudo systemctl enable dp-agent.service",
      // install & enable dp-observer
      "sudo mv /tmp/dp-observer.service /lib/systemd/system/dp-observer.service",
      "sudo mv /tmp/dp-observer.gz /home/ec2-user && sudo gunzip /home/ec2-user/dp-observer.gz",
      "sudo chmod +x /home/ec2-user/dp-observer && sudo systemctl enable dp-observer.service"
    ]
  }
}
