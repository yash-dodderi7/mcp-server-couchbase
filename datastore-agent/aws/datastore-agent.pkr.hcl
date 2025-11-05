packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.10"
      source = "github.com/hashicorp/amazon"
    }
  }
}
variable "product_pkg_name" { type = string }
variable "product_version" { type = string }
variable "product_bld_num" { type = string }
variable "product_arch" { type = string }
variable "ami_name" { type = string }
variable "region" { type = string }
variable "ami_regions" { type = list(string) }

locals {
  ami_arch = var.product_arch
  instance_type = local.ami_arch == "arm64" ? "t4g.micro" : "t2.micro"
  exporter_arch = var.product_arch
  source_ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_arch}-server-*"
}

source "amazon-ebs" "cc" {
  ami_name      = "${var.ami_name}"
  ami_regions   = "${var.ami_regions}"
  instance_type = "${local.instance_type}"
  region        = "${var.region}"
  ssh_timeout   = "15m"
  ssh_username    = "ubuntu"
  aws_polling {
    delay_seconds = 30
    max_attempts = 120
  }
  metadata_options {
    http_endpoint = "enabled"
    http_put_response_hop_limit = "1"
    http_tokens   = "required"
  }
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
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
  }
}

// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.amazon-ebs.cc"]
  provisioner "file" {
    destination = "/tmp/"
    sources = [
      "${var.product_pkg_name}",
      "agents/${var.product_arch}/dp-observer.gz",
      "agents/${var.product_arch}/dp-runtime-agent.gz",
      "agents/${var.product_arch}/datastore-agent.gz",
      "datastore-agent.service",
      "dp-observer.service",
      "dp-runtime-agent.service",
      "node-exporter.service",
      "process-exporter.service",
      "journald.conf"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "CLOUD_PROVIDER=aws",
      "PRODUCT_ARCH=${var.product_arch}",
      "PRODUCT_PKG_NAME=${var.product_pkg_name}"
    ]
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "provision.sh"
  }
}
