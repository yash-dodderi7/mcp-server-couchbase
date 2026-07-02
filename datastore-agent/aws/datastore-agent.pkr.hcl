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
  ami_arch             = var.product_arch
  // AV-133308: the kernel series is enforced in common_scripts/provision.sh
  // (swap to the GA 6.8 LTS kernel), so the base AMI can track Canonical's
  // latest again. This also reverts CBD-6720's temporary 20260515 hardcode.
  source_ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_arch}-server-*"
  kernel               = "6.8"
  instance_type        = local.ami_arch == "arm64" ? "t4g.micro" : "t3.micro"
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
    owners      = ["099720109477"] // Canonical
  }
  tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
    kernel        = "${local.kernel}"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
    kernel        = "${local.kernel}"
  }
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

  // Create ec2-user which is required by Capella control plane.
  // Packer AWS builder always connects to the temporary instance
  // using the default SSH user defined by the base AMI.
  // It does not support ussing a different user for the initial connection.
  // Hence, the temporary instance is provisioned using "ubuntu" user.
  // ec-user is created afterward.
  provisioner "shell" {
    script = "create_user.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "CLOUD_PROVIDER=aws",
      "PRODUCT_ARCH=${var.product_arch}",
      "COUCHBASE_SERVER_PKG=${local.couchbase_server_pkg}"
    ]
    pause_before = "5s"
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "provision.sh"
  }
}
