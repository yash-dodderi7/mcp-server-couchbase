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
variable "ns_server_profile" { type = string }
variable "product_arch" { type = string }
variable "dp_service" { type = string }
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
variable "agent_sha" { type = string }

locals {
  platform = "linux"
  image_sku = var.product_arch == "amd64" ? "server" : "server-arm64"
  image_offer = "ubuntu-24_04-lts"
  vm_size = var.product_arch == "amd64" ? "Standard_D2s_v5" : "Standard_D2ps_v5"

  // couchbase-server.service or enterprise-analytics.service
  product_service = var.ns_server_profile == "analytics_provisioned" ? "enterprise-analytics" : "couchbase-server"
}


// managed_image_* is legacy, prefer method is building direct to image gallery.
// Managed images are retained until we can fully migrate off them.
// Azure doesn't support managed images on Arm64.
// Direct-to-Gallery skips the creation of a standalone Image resource.
// It captures the VM VHD directly into a Gallery Image Version.

// Azure machine image Builders
source "azure-arm" "cc-x64" {
  azure_tags = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    product_version      = "${var.product_version}"
    image_version        = "${var.image_version}"
    agent                = "${var.agent_sha}"
    kernel               = "6.8"
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

  managed_image_name                 = var.image_name
  managed_image_resource_group_name  = var.resource_group
  managed_image_storage_account_type = "Standard_LRS"

  client_id              = "${var.client_id}"
  client_secret          = "${var.client_secret}"
  image_offer            = "${local.image_offer}"
  image_publisher        = "canonical"
  image_sku              = "${local.image_sku}"
  os_type                = "Linux"
  location               = "${var.region}"
  subscription_id        = "${var.subscription_id}"
  vm_size                = "${local.vm_size}"
  ssh_username           = "ec2-user"
}

source "azure-arm" "cc-Arm64" {
  azure_tags = {
    owner                = "couchbase-capella"
    creator              = "build-team"
    arch                 = "${var.product_arch}"
    product_version      = "${var.product_version}"
    image_version        = "${var.image_version}"
    agent                = "${var.agent_sha}"
    kernel               = "6.8"
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

  client_id              = "${var.client_id}"
  client_secret          = "${var.client_secret}"
  image_offer            = "${local.image_offer}"
  image_publisher        = "canonical"
  image_sku              = "${local.image_sku}"
  os_type                = "Linux"
  location               = "${var.region}"
  subscription_id        = "${var.subscription_id}"
  vm_size                = "${local.vm_size}"
  ssh_username           = "ec2-user"
}
// a build block invokes sources and runs provisioning steps on them.
build {
  sources = [var.product_arch == "amd64" ? "source.azure-arm.cc-x64" : "source.azure-arm.cc-Arm64"]
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
      "CLOUD_PROVIDER=azure",
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
