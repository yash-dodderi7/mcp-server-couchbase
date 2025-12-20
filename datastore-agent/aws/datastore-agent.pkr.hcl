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
  ami_name             = var.ami_name != "" ? var.ami_name : "datastore-agent-${var.product_version}-${var.product_arch}"
  ami_arch             = var.product_arch == "arm64" ? "arm64" : "x86_64"
  source_ami_name      = "amzn2-ami-kernel-5.10-hvm-2.0.*-${local.ami_arch}-gp2"
  instance_type        = var.product_arch == "arm64" ? "t4g.micro" : "t3.micro"
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
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
  }
  ssh_username = "ec2-user"
}

build {
  sources = ["source.amazon-ebs.cc"]
  provisioner "file" {
    destination = "/tmp/"
    sources     = [
      "${local.couchbase_server_pkg}",
      "agents/${var.product_arch}/datastore-agent.gz",
      "agents/${var.product_arch}/dp-observer.gz",
      "agents/${var.product_arch}/dp-runtime-agent.gz",
      "datastore-agent.service",
      "dp-observer.service",
      "dp-runtime-agent.service",
      "node-exporter.service",
      "process-exporter.service",
      "journald.conf",
      "provision.sh"
    ]
  }
  provisioner "shell" {
    environment_vars = [
      "PRODUCT_ARCH=${var.product_arch}",
      "COUCHBASE_SERVER_PKG=${local.couchbase_server_pkg}"
    ]
    pause_before = "5s"
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "provision.sh"
  }
}
