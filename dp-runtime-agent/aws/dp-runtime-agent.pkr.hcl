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
variable "product_arch" { type = string }

locals {
  product_name    = "dp-runtime-agent"
  ami_name        = var.ami_name != "" ? var.ami_name : "${local.product_name}-${var.product_version}-${var.product_arch}"
  process-exporter_version = "0.8.7"
  process-exporter_package = "process-exporter_${local.process-exporter_version}_linux_${var.product_arch}"
  node_exporter_version    = "1.9.1"
  node_exporter_package    = "node_exporter-${local.node_exporter_version}.linux-${var.product_arch}"

  // Use a base image with GPU support, required by model-serving-agent
  // This is owned by AWS rather than Canonical
  source_ami_name = var.product_arch == "amd64" ? "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*" : "Deep Learning ARM64 Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*"
  instance_type = var.product_arch == "arm64" ? "t4g.micro" : "t2.micro"
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
    sources     = [
      "agents/${var.product_arch}/${local.product_name}.gz",
      "agents/${var.product_arch}/dp-observer.gz",
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
