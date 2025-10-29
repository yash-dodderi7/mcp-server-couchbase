packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.2.2"
      source = "github.com/hashicorp/googlecompute"
    }
  }
}
variable "product_pkg_name" { type = string }
variable "product_version" { type = string }
variable "product_bld_num" { type = string }
variable "ns_server_profile" { type = string }
variable "product_arch" { type = string }
variable "image_name" { type = string }
variable "image_version" { type = string }
variable "dp_service" { type = string }
variable "project_id" { type = string }
variable "network_id" { type = string }
variable "access_token" { type = string }
variable "agent_sha" { type = string }

locals {
  // arm64 and amd64 specific settings
  //   pd-standard is the default.  It is not compatible with arm64
  //   arm64 is currently not available in us-central1-a
  platform = "linux"
  disk_type = var.product_arch == "amd64" ? "pd-standard" : "hyperdisk-balanced"
  source_image_family = var.product_arch == "amd64" ? "ubuntu-2404-lts-amd64" : "ubuntu-2404-lts-arm64"
  machine_type = var.product_arch == "amd64" ? "n2-standard-2" : "c4a-standard-1"
  zone = var.product_arch == "amd64" ? "us-central1-a" : "us-east4-b"

  // couchbase-server.service or enterprise-analytics.service
  product_service = var.ns_server_profile == "analytics_provisioned" ? "enterprise-analytics" : "couchbase-server"
}

source "googlecompute" "cc" {
  access_token = "${var.access_token}"
  project_id = "${var.project_id}"
  machine_type = "${local.machine_type}"
  source_image_family = "${local.source_image_family}"
  zone = "${local.zone}"
  disk_type = "${local.disk_type}"
  disk_size = 10
  // both network and subnetwork name are identicial.
  network = "${var.network_id}"
  subnetwork = "${var.network_id}"
  ssh_username = "ec2-user"
  image_name = "${var.image_name}"

  image_labels = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    version              = "${var.image_version}"
    build                = "${var.product_bld_num}"
    agent                = "${var.agent_sha}"
  }
}

// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.googlecompute.cc"]
  provisioner "file" {
    destination = "/tmp/"
    sources      = [
      "${var.product_pkg_name}",
      "agents/${var.product_arch}/${var.dp_service}.gz",
      "agents/${var.product_arch}/dp-observer.gz",
      "../common_scripts/${var.dp_service}.service",
      "../common_scripts/dp-observer.service",
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
  provisioner "shell" {
    environment_vars = [
      "CLOUD_PROVIDER=gcp",
      "DP_SERVICE=${var.dp_service}",
      "NS_SERVER_PROFILE=${var.ns_server_profile}",
      "PRODUCT_SERVICE=${local.product_service}",
      "PRODUCT_ARCH=${var.product_arch}",
      "PRODUCT_PKG_NAME=${var.product_pkg_name}"
    ]
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "../common_scripts/provision.sh"
  }
}
