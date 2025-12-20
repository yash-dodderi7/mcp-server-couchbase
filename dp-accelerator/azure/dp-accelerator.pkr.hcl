packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2.4.0"
    }
  }
}

variable "product_pkg_name" { type = string }
variable "product_version" { type = string }
variable "product_bld_num" { type = string }
variable "product_arch" { type = string }
variable "subscription_id" { type = string }
variable "client_id" { type = string }
variable "client_secret" { type = string }
variable "resource_group" { type = string }
variable "image_gallery" { type = string }
variable "image_definition" { type = string }
variable "image_name" { type = string }
variable "image_version" { type = string }
variable "region" { type = string }
variable "replication_regions" { type = list(string) }

locals {
  platform = "linux"
  image_sku = "server"
  image_offer = "ubuntu-24_04-lts"
  couchbase_server_pkg = var.product_pkg_name
  image_name             = var.image_name != "" ? var.image_name : "dp-accelerator-${var.product_version}-${var.product_arch}"
}

// Azure machine image Builder
source "azure-arm" "cc" {
  azure_tags = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    product_version      = "${var.product_version}"
    image_version        = "${var.image_version}"
  }

  shared_image_gallery_destination {
    subscription         = "${var.subscription_id}"
    resource_group       = "${var.resource_group}"
    gallery_name         = "${var.image_gallery}"
    image_name           = "${var.image_definition}"
    storage_account_type = "Standard_LRS"
    image_version        = "${var.image_version}"
    replication_regions  = "${var.replication_regions}"
  }

  client_id                          = "${var.client_id}"
  client_secret                      = "${var.client_secret}"
  image_offer                        = "${local.image_offer}"
  image_publisher                    = "canonical"
  image_sku                          = "${local.image_sku}"
  managed_image_name                 = "${var.image_name}"
  managed_image_resource_group_name  = "${var.resource_group}"
  managed_image_storage_account_type = "Standard_LRS"
  os_type                            = "Linux"
  location                           = "${var.region}"
  subscription_id                    = "${var.subscription_id}"
  vm_size                            = "Standard_D2s_v5"
  ssh_username                       = "ubuntu"
}

// a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.azure-arm.cc"]
  provisioner "file" {
    destination = "/tmp/"
    sources      = [
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
