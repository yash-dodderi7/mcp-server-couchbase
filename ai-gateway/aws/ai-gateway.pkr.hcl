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
variable "product_pkg_name" {
  type = string
}
variable "agent_sha" {
  type = string
}

locals {
  product                  = "ai-gateway"
  ami_name                 = var.ami_name != "" ? var.ami_name : "ai-gateway-${var.product_version}-${local.arch}"
  source_ami_name          = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.product_arch}-server*"
  instance_type            = var.product_arch == "arm64" ? "t4g.micro" : "t2.micro"
  process-exporter_version = "0.8.7"
  process-exporter_package = "process-exporter_${local.process-exporter_version}_linux_${var.product_arch}"
  node_exporter_version    = "1.9.1"
  node_exporter_package    = "node_exporter-${local.node_exporter_version}.linux-${var.product_arch}"
}

source "amazon-ebs" "cc" {
  ami_name      = "${local.ami_name}"
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
    owners      = ["amazon"]
  }
  tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    version       = "${var.product_version}"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    version       = "${var.product_version}"
  }
  ssh_username = "ubuntu"
}


// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.amazon-ebs.cc"]
  provisioner "file" {
    destination = "/tmp/"
    sources = [
      "${var.product_pkg_name}",
      "agents/${var.product_arch}/dp-observer.gz",
      "ai-gateway.service",
      "dp-observer.service",
      "node-exporter.service",
      "process-exporter.service",
      "journald.conf",
      "iptables-firewall.sh",
      "dp-firewall.service"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "PRODUCT=${local.product}",
      "VERSION=${var.product_version}",
      "BLD_NUM=${var.product_bld_num}",
      "PRODUCT_ARCH=${var.product_arch}",
      "PRODUCT_PKG_NAME=${var.product_pkg_name}",
      "NODE_EXPORTER_VERSION=${local.node_exporter_version}",
      "NODE_EXPORTER_PACKAGE=${local.node_exporter_package}",
      "PROCESS_EXPORTER_VERSION=${local.process-exporter_version}",
      "PROCESS_EXPORTER_PACKAGE=${local.process-exporter_package}"
    ]
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "provision.sh"
  }
}
