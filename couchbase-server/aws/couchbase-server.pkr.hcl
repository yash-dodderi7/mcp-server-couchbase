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
variable "ns_server_profile" { type = string }
variable "product_arch" { type = string }
variable "dp_service" { type = string }
variable "agent_sha" { type = string }
variable "ami_name" { type = string }
variable "region" { type = string }
variable "ami_regions" { type = list(string) }

locals {
  ami_arch = var.product_arch
  instance_type = local.ami_arch == "arm64" ? "t4g.micro" : "t3.micro"
  exporter_arch = var.product_arch
  // AV-133308: the kernel series is enforced in common_scripts/provision.sh
  // (swap to the GA 6.8 LTS kernel), so the base AMI can track Canonical's
  // latest again. This also reverts CBD-6720's temporary 20260515 hardcode.
  source_ami_name = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${local.ami_arch}-server-*"
  product_service = var.ns_server_profile == "analytics_provisioned" ? "enterprise-analytics" : "couchbase-server"
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
    agent       = "${var.agent_sha}"
    kernel        = "6.8"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
    agent       = "${var.agent_sha}"
    kernel        = "6.8"
  }
}

// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.amazon-ebs.cc"]
  provisioner "file" {
    destination = "/tmp/"
    sources = [
      "${var.product_pkg_name}",
      "agents/${var.product_arch}/${var.dp_service}.gz",
      "agents/${var.product_arch}/dp-observer.gz",
      "agents/${var.product_arch}/dp-runtime-agent.gz",
      "../common_scripts/${var.dp_service}.service",
      "../common_scripts/dp-observer.service",
      "../common_scripts/dp-runtime-agent.service",
      "../common_scripts/node-exporter.service",
      "../common_scripts/process-exporter.service",
      "../common_scripts/pushgateway.service",
      "../common_scripts/disable-thp.service",
      "../common_scripts/journald.conf",
      "../common_scripts/iptables-firewall.sh",
      "../common_scripts/dp-firewall.service",
      "../common_scripts/disable-mglru.service"
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
      "DP_SERVICE=${var.dp_service}",
      "NS_SERVER_PROFILE=${var.ns_server_profile}",
      "PRODUCT_SERVICE=${local.product_service}",
      "PRODUCT_ARCH=${var.product_arch}",
      "PRODUCT_PKG_NAME=${var.product_pkg_name}",
      "PRODUCT_VERSION=${var.product_version}"
    ]
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "../common_scripts/provision.sh"
  }
}
