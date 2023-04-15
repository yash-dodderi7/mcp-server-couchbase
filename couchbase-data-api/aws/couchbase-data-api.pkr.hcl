# Follow the steps below to generate couchbase-data-api ami
# 1. cp .env.example .env
# 2. Update .env with appropriate values
# 3. source .env
# 4. AWS_PROFILE=<AMI Profile Name> packer build couchbase-data-api.pkr.hcl

variable "region" {
  type = string
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

variable "ami_name" {
  type = string
}

variable "product_platform" {
  type = string
}

variable "product_arch" {
  type = string
}

variable "agent_sha" {
  type = string
}

locals {
  process-exporter_version = "0.7.5"
  process-exporter_package = "process-exporter_${local.process-exporter_version}_linux_arm64"
  node_exporter_version = "1.1.2"
  node_exporter_package = "node_exporter-${local.node_exporter_version}.linux-arm64"

  ami_arch = var.product_arch == "aarch64" ? "arm64" : "x86_64"
  instance_type = local.ami_arch == "arm64" ? "t4g.micro" : "t2.micro"

  fluent-bit_version = "1.9"

  ## The dp service that is being put on the image.
  dp_service = "dp-serverless"

  ## The user to use for starting the service
  service_user = "dataapi"
}

source "amazon-ebs" "cc" {
  ami_name      = "${var.ami_name}"
  instance_type = "${local.instance_type}"
  region        = "${var.region}"
  source_ami_filter {
    filters = {
      name                = "amzn2-ami-kernel-5.10-hvm-2.0.*-${local.ami_arch}-gp2"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }
  tags = {
    owner       = "couchbase-capella"
    creator     = "build-team"
    arch        = "${local.ami_arch}"
    version     = "${var.product_version}-${var.product_bld_num}"
    agent       = "${var.agent_sha}"
  }
  snapshot_tags = {
    owner       = "couchbase-capella"
    creator     = "build-team"
    arch        = "${local.ami_arch}"
    version     = "${var.product_version}-${var.product_bld_num}"
    agent       = "${var.agent_sha}"
  }
  ssh_username = "ec2-user"
}

# a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.amazon-ebs.cc"]

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
    source      = "${var.product_name}.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "${var.product_name}_${var.product_version}-${var.product_bld_num}-${var.product_platform}.${var.product_arch}.tar.gz"
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
   destination = "/tmp/fluent-bit.conf"
   source = "fluent-bit.conf"
  }

  provisioner "file" {
   destination = "/tmp/fluent-bit.repo"
   source = "fluent-bit.repo"
  }

  provisioner "file" {
    destination = "/tmp/agent.config"
    source = "shoreline.agent.config"
  }

  provisioner "shell" {
    inline = [
      "sleep 10",
      "sudo mv /tmp/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 755 /etc/systemd/journald.conf",
      // Create user
      "sudo useradd -d /home/${local.service_user} -m ${local.service_user}",
      "sudo chown -R ${local.service_user}:${local.service_user} /home/${local.service_user}",
      "sudo mv /tmp/${var.product_name}.service /lib/systemd/system/${var.product_name}.service",
      "sudo tar -xzf /tmp/${var.product_name}_${var.product_version}-${var.product_bld_num}-${var.product_platform}.${var.product_arch}.tar.gz -C /home/${local.service_user}",
      "sudo chown -R ${local.service_user}:${local.service_user} /home/${local.service_user}",
      "sudo chmod +x /home/${local.service_user}/rest-server",
      "sudo systemctl enable ${var.product_name}.service",
      "sudo rm /tmp/${var.product_name}_${var.product_version}-${var.product_bld_num}-${var.product_platform}.${var.product_arch}.tar.gz",
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
      // Install and enable dp_service
      "sudo mv /tmp/${local.dp_service}.service /lib/systemd/system/${local.dp_service}.service",
      "sudo mv /tmp/${local.dp_service}.gz /home/ec2-user",
      "sudo gunzip /home/ec2-user/${local.dp_service}.gz",
      "sudo chmod +x /home/ec2-user/${local.dp_service}",
      "sudo systemctl enable ${local.dp_service}.service",
      // Install firewall service
      "sudo mv /tmp/dp-firewall.service /lib/systemd/system/dp-firewall.service",
      "sudo mv /tmp/iptables-firewall.sh /home/ec2-user",
      "sudo chmod +x /home/ec2-user/iptables-firewall.sh",
      "sudo chown root:root /home/ec2-user/iptables-firewall.sh",
      "sudo systemctl start dp-firewall.service",
      "sudo systemctl enable dp-firewall.service",
      // Install and enable fluent-bit
      // https://docs.fluentbit.io/manual/installation/linux/amazon-linux#single-line-install
      "sudo mv /tmp/fluent-bit.repo /etc/yum.repos.d/.",
      "sudo yum install fluent-bit -y",
      "sudo mv /tmp/fluent-bit.conf /etc/fluent-bit/fluent-bit.conf",
      "sudo systemctl enable fluent-bit.service",
      // Install the Shoreline agent
      "sudo mkdir -p /home/ec2-user/shoreline",
      "sudo mv /tmp/agent.config /home/ec2-user/shoreline",
      "sudo chown -R ec2-user:ec2-user /home/ec2-user/shoreline",
      "pushd /home/ec2-user/shoreline",
      "curl -L 'https://shorelinedownload.blob.core.windows.net/agent/vm_base_install_0.6.3.sh' -o vm_base_install.sh",
      "chmod +x vm_base_install.sh",
      "sudo ./vm_base_install.sh",
      // Shoreline start-up is handled by dp-agent. Docker & containerd will start as dependencies once the Shoreline agent starts
      "sudo systemctl disable shoreline.shoreline.service shoreline.node_exporter.service docker.service containerd.service",
      // Create the Shoreline secrets directory, allowing dp-agent to bootstrap it
      "sudo mkdir -p /var/lib/shoreline/agent/secrets",
      "sudo chown ec2-user:ec2-user /var/lib/shoreline/agent/secrets",
      // Prevent the agent startup script from printing secrets to the system log
      "sudo sed -i 's/^set -o xtrace/#set -o xtrace/g' /usr/bin/shoreline-agent",
      // Install jq to enable Shoreline users to format and manipulate API output
      "sudo yum install -y jq"
    ]
  }
}
