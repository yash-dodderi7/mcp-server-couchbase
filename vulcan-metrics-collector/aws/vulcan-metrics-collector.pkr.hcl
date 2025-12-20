packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.10"
      source = "github.com/hashicorp/amazon"
    }
  }
}
variable "product_version" {
  type    = string
  default = "0.0.0"
}
variable "ami_name" {
  type    = string
  default = ""
}
variable "region" {
  type    = string
}
variable "ami_regions" {
  type    = list(string)
}

locals {
  arch            = "amd64"
  ami_name        = var.ami_name != "" ? var.ami_name : "vulcan-metrics-collector-${var.product_version}-${local.arch}"
  source_ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server*"
  instance_type   = "t3.micro"
  process_exporter_version = "0.8.7"
  process_exporter_package = "process-exporter_${local.process_exporter_version}_linux_${local.arch}"
  node_exporter_version = "1.9.1"
  node_exporter_package = "node_exporter-${local.node_exporter_version}.linux-${local.arch}"
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
    sources      = [
      "metrics-collector.zip",
      "agents/${local.arch}/dp-observer.gz",
      "dp-observer.service",
      "node-exporter.service",
      "process-exporter.service",
      "journald.conf",
      "start-vulcan-metrics-collector.sh",
      "vulcan-metrics-collector.service",
      "vulcan-metrics-collector-sudoer",
      "provision.sh"
    ]
  }
  provisioner "shell" {
    pause_before = "5s"
    environment_vars = [
      "NODE_EXPORTER_VERSION=${local.node_exporter_version}",
      "NODE_EXPORTER_PACKAGE=${local.node_exporter_package}",
      "PROCESS_EXPORTER_VERSION=${local.process_exporter_version}",
      "PROCESS_EXPORTER_PACKAGE=${local.process_exporter_package}"
    ]
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "provision.sh"
  }
}
