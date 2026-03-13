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

  // Use a GPU enabled image as the base, required by model-serving-agent
  // This is owned by AWS rather than Canonical
  source_ami_name = var.product_arch == "amd64" ? "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*" : "Deep Learning ARM64 Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*"
  instance_type = var.product_arch == "arm64" ? "t4g.micro" : "t3.micro"
}

source "amazon-ebs" "cc" {
  ami_name      = "${local.ami_name}"
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
      "journald.conf"
    ]
  }

  // Create ec2-user which is required by Capella control plane.
  // Packer AWS builder always connects to the temporary instance
  // using the default SSH user defined by the base AMI.
  // It does not support using a different user for the initial connection.
  // Hence, the temporary instance is provisioned using "ubuntu" user.
  // ec-user is created afterward.
  provisioner "shell" {
    script = "create_user.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "PRODUCT_ARCH=${var.product_arch}"
    ]
    pause_before = "5s"
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "provision.sh"
  }
}
