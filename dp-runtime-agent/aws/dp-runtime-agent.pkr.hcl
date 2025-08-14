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

locals {
  product_name    = "dp-runtime-agent"
  product_arch    = "amd64"
  ami_name        = var.ami_name != "" ? var.ami_name : "${local.product_name}-${var.product_version}-${local.product_arch}"
  source_ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server*"
  instance_type   = "t2.micro"
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

build {
  sources = ["source.amazon-ebs.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "agents/${local.product_arch}/${local.product_name}"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "${local.product_name}.service"
  }

  provisioner "file" {
    destination = "/tmp/journald.conf"
    source = "journald.conf"
  }

  provisioner "file" {
    destination = "/tmp/provision.sh"
    source = "provision.sh"
  }

  provisioner "shell" {
    pause_before = "5s"
    script = "provision.sh"
  }
}
