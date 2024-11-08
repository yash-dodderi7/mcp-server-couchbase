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

locals {
  product = "model-serving-agent"
  product_pkg_name = "${local.product}-${var.product_version}-${var.product_bld_num}-linux-${var.product_arch}"
  ami_arch = var.product_arch == "amd64" ? "x86_64" : "arm64"
  source_ami_name = "Deep Learning Base OSS Nvidia Driver AMI (Amazon Linux 2) Version 65.8"
  instance_type = var.product_arch == "arm64" ? "t4g.micro" : "t2.micro"
}

source "amazon-ebs" "cc" {
  ami_name      = "${var.ami_name}"
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
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
  }
  snapshot_tags = {
    owner         = "couchbase-capella"
    creator       = "build-team"
    arch          = "${local.ami_arch}"
    version       = "${var.product_version}-${var.product_bld_num}"
  }
  ssh_username = "ec2-user"
}

build {
  sources = ["source.amazon-ebs.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "${local.product_pkg_name}.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "${local.product}.service"
  }

  provisioner "file" {
    destination = "/tmp/journald.conf"
    source = "journald.conf"
  }

  provisioner "shell" {
    pause_before = "5s"
    inline = [
      "sudo mv /tmp/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 755 /etc/systemd/journald.conf",

      // Set swappiness to 1 to avoid swapping excessively
      "sudo sh -c 'echo \"vm.swappiness = 1\" >> /etc/sysctl.conf'",

      // Install docker
      // reference: https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-docker.html
      "sudo yum update -y",
      "sudo amazon-linux-extras install docker",
      "sudo yum clean all",
      "sudo service docker start",
      "sleep 5",
      "sudo service docker status",
      "sudo usermod -a -G docker ec2-user",

      // Install gvisor and set it as default docker runtime
      // reference: https://gvisor.dev/docs/user_guide/install/
      "wget https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/runsc",
      "wget https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/runsc.sha512",
      "wget https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/containerd-shim-runsc-v1",
      "wget https://storage.googleapis.com/gvisor/releases/release/latest/$(uname -m)/containerd-shim-runsc-v1.sha512",
      "sha512sum -c runsc.sha512 -c containerd-shim-runsc-v1.sha512",
      "rm -f *.sha512",
      "chmod a+rx runsc containerd-shim-runsc-v1",
      "sudo mv runsc containerd-shim-runsc-v1 /usr/local/bin",
      "sudo /usr/local/bin/runsc install",
      "sudo service docker reload",
      "sudo docker info | grep io.containerd.runc || exit",

      // Install and enable model-serving-agent
      "sudo mv /tmp/${local.product}.service /lib/systemd/system/${local.product}.service",
      "sudo mv /tmp/${local.product_pkg_name}.gz /home/ec2-user/${local.product}.gz",
      "sudo gunzip /home/ec2-user/${local.product}.gz",
      "sudo chmod +x /home/ec2-user/${local.product}",
      "sudo systemctl enable ${local.product}.service",

      // reload docker
      "sudo service docker reload",
    ]
  }
}
