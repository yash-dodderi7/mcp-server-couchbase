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

locals {
  product = "vulcan"
  product_pkg_name = "${local.product}-${var.product_version}-${var.product_bld_num}-${var.product_arch}"
  source_ami_name = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server*"
  //unstructured requires a lot of memory during installation, hence t2.medium instead of t2.micro
  instance_type = var.product_arch == "arm64" ? "t4g.medium" : "t2.medium"
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
    owners      = ["amazon"]
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
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${var.product_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
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

  provisioner "shell" {
    pause_before = "5s"
    script = "provision.sh"
  }
}
