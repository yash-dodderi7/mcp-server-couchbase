packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.10"
      source = "github.com/hashicorp/amazon"
    }
  }
}

variable "product_pkg_name" { type = string }
variable "product_arch" { type = string }
variable "product_version" { type = string }
variable "product_bld_num" { type = string }
variable "ami_name" { type = string }
variable "region" { type = string }
variable "ami_regions" { type = list(string) }

locals {
  couchbase_server_pkg = var.product_pkg_name
  ami_name             = var.ami_name != "" ? var.ami_name : "dp-accelerator-${var.product_version}-${var.product_arch}"
  source_ami_name      = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.product_arch}-server*"
  instance_type        = var.product_arch == "arm64" ? "t4g.micro" : "t2.micro"
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
    owners      = ["099720109477"] // Canonical
  }
  tags = {
    owner          = "couchbase-capella"
    creator        = "build-team"
    arch           = "${var.product_arch}"
    version        = "${var.product_version}-${var.product_bld_num}"
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
    destination = "/tmp/"
    sources     = [
      "${local.couchbase_server_pkg}",
      "agents/${var.product_arch}/dp-accelerator.gz",
      "agents/${var.product_arch}/dp-observer.gz",
      "../common_scripts/dp-accelerator.service",
      "../common_scripts/dp-observer.service",
      "../common_scripts/node-exporter.service",
      "../common_scripts/process-exporter.service",
      "../common_scripts/journald.conf",
      "../common_scripts/provision.sh"
    ]
  }
  provisioner "shell" {
    environment_vars = [
      "PRODUCT_ARCH=${var.product_arch}",
      "COUCHBASE_SERVER_PKG=${local.couchbase_server_pkg}"
    ]
    pause_before = "5s"
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "../common_scripts/provision.sh"
  }
}
