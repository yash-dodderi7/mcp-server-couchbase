packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.2" # preferably "~> 1.2.0" for latest patch version
      source = "github.com/hashicorp/amazon"
    }
  }
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
variable "product_arch" {
  type = string
}

variable "agent_sha" {
  type = string
}

locals {
  product = "vulcan"
  product_pkg_name = "${local.product}-${var.product_version}-${var.product_bld_num}-${var.product_arch}"
  source_ami_name = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server*"
  //unstructured requires a lot of memory during installation, hence t2.medium instead of t2.micro
  instance_type = var.product_arch == "arm64" ? "t4g.medium" : "t2.medium"
  process_exporter_version = "0.8.3"
  node_exporter_version = "1.1.2"
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
    owners      = ["099720109477"] // Canonical
  }
  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 20
  }
  tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${var.product_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
    agent         = "${var.agent_sha}"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${var.product_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
    agent         = "${var.agent_sha}"
  }
  ssh_username = "ubuntu"
}

build {
  sources = ["source.amazon-ebs.cc"]

  provisioner "file" {
    destination = "/tmp/${local.product}.tar.gz"
    source      = "${local.product_pkg_name}.tar.gz"
  }
  provisioner "file" {
    destination = "/tmp/provision.sh"
    source = "provision.sh"
  }
  provisioner "file" {
    destination = "/tmp/journald.conf"
    source = "journald.conf"
  }
  provisioner "file" {
    destination = "/tmp/${local.product}.service"
    source = "${local.product}.service"
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

  provisioner "shell" {
    pause_before = "5s"
    environment_vars = [
      "process_exporter_version=${local.process_exporter_version}",
      "process_exporter_package=process-exporter_${local.process_exporter_version}_linux_${var.product_arch}",
      "node_exporter_version=${local.node_exporter_version}",
      "node_exporter_package=node_exporter-${local.node_exporter_version}.linux-${var.product_arch}"
    ]
    script = "provision.sh"
  }
}
