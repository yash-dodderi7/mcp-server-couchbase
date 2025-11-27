packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.2.2"
      source = "github.com/hashicorp/googlecompute"
    }
  }
}

variable "product_pkg_name" { type = string }
variable "product_arch" { type = string }
variable "product_version" { type = string }
variable "product_bld_num" { type = string }
variable "image_name" { type = string }
variable "image_version" { type = string }
variable "project_id" { type = string }
variable "network_id" { type = string }
variable "access_token" { type = string }

locals {
  couchbase_server_pkg = var.product_pkg_name
  image_name             = var.image_name != "" ? var.image_name : "dp-accelerator-${var.image_version}-${var.product_arch}"
  // arm64 and amd64 specific settings
  //   pd-standard is the default.  It is not compatible with arm64
  //   arm64 is currently not available in us-central1-a
  platform = "linux"
  disk_type = var.product_arch == "amd64" ? "pd-standard" : "hyperdisk-balanced"
  source_image_family = var.product_arch == "amd64" ? "ubuntu-2404-lts-amd64" : "ubuntu-2404-lts-arm64"
  machine_type = var.product_arch == "amd64" ? "n2-standard-2" : "c4a-standard-1"
  zone = var.product_arch == "amd64" ? "us-central1-a" : "us-east4-b"
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
  ssh_username = "ubuntu"
  image_name = "${var.image_name}"

  image_labels = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    version              = "${var.image_version}"
    build                = "${var.product_bld_num}"
  }
}

build {
  sources = ["source.googlecompute.cc"]
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
