variable "product_version" {
  type = string
}
variable "product_bld_num" {
  type = string
}
variable "ami_name" {
  type = string
}
variable "region" {
  type = string
}
variable "ami_regions" {
  type = list(string)
}
variable "product_arch" {
  type = string
}
variable "product_pkg_name" {
  type = string
}

locals {
  product = "model-serving-agent"
  ami_name = var.ami_name != "" ? var.ami_name : "${local.product}-${var.product_version}-${var.product_bld_num}-${var.product_arch}"
  // Use a base image with inbuilt GPU support
  // This is owned by AWS rather than Canonical
  source_ami_name = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*"
  instance_type = var.product_arch == "arm64" ? "t4g.micro" : "t2.micro"
}

source "amazon-ebs" "cc" {
  ami_name      = "${local.ami_name}"
  ami_regions   = "${var.ami_regions}"
  instance_type = "${local.instance_type}"
  region        = "${var.region}"
  source_ami_filter {
    filters = {
      // use a base image with inbuilt GPU support
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
    arch          = "${var.product_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${var.product_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
  }
  ssh_username = "ubuntu"
}

build {
  sources = ["source.amazon-ebs.cc"]
  provisioner "file" {
    destination = "/tmp/"
    sources     = [
      "${var.product_pkg_name}",
      "${local.product}.service",
      "journald.conf"
    ]
  }

  provisioner "shell" {
    pause_before = "5s"
    environment_vars = [
      "PRODUCT=${local.product}",
      "VERSION=${var.product_version}",
      "BLD_NUM=${var.product_bld_num}",
      "PRODUCT_ARCH=${var.product_arch}",
      "PRODUCT_PKG_NAME=${var.product_pkg_name}"
    ]
    execute_command = "sudo -E sh -x -c '{{ .Vars }} {{ .Path }}'"
    script = "provision.sh"
  }
}
