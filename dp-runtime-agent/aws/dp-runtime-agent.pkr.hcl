packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.10"
      source = "github.com/hashicorp/amazon"
    }
  }
}
variable "product_version" { type = string }
variable "product_bld_num" { type = string }
variable "ami_name" { type = string }
variable "region" { type = string }
variable "ami_regions" { type = list(string) }

locals {
  product_name    = "dp-runtime-agent"
  product_arch    = "amd64"
  ami_name        = var.ami_name != "" ? var.ami_name : "${local.product_name}-${var.product_version}-${local.product_arch}"
  source_ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server*"
  instance_type   = "t2.micro"
  process-exporter_version = "0.8.7"
  process-exporter_package = "process-exporter_${local.process-exporter_version}_linux_${local.product_arch}"
  node_exporter_version    = "1.9.1"
  node_exporter_package    = "node_exporter-${local.node_exporter_version}.linux-${local.product_arch}"
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
    sources     = [
      "agents/${local.product_arch}/${local.product_name}.gz",
      "agents/${local.product_arch}/dp-observer.gz",
      "${local.product_name}.service",
      "dp-observer.service",
      "node-exporter.service",
      "process-exporter.service",
      "journald.conf",
      "provision.sh"
    ]
  }
  provisioner "shell" {
    environment_vars = [
      "NODE_EXPORTER_VERSION=${local.node_exporter_version}",
      "NODE_EXPORTER_PACKAGE=${local.node_exporter_package}",
      "PROCESS_EXPORTER_VERSION=${local.process-exporter_version}",
      "PROCESS_EXPORTER_PACKAGE=${local.process-exporter_package}"
    ]
    pause_before = "5s"
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "provision.sh"
  }
}
