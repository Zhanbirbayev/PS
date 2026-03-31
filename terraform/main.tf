terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.50"
    }
  }
}

provider "openstack" {
  user_name   = "18531_nu-musca"
  tenant_name = "nu-musca 1"
  password    = "********"
  auth_url    = "https://auth.pscloud.io/v3/"
  region      = "kz-ala-1"
}

##############################
# Variables & Data
##############################
variable "image_id" {
  default = "3f5b3bae-e421-4d1f-9f1c-45e363187b11"
}

variable "private_key_path" {
  default = "C:/Users/Nurzhan.Zhanbirbayev/Documents/PS/pscloud_key"
}

variable "vms" {
  default = {
    "haproxy" = "192.168.0.10"
    "web1"    = "192.168.0.11"
    "web2"    = "192.168.0.12"
    "web3"    = "192.168.0.13"
    "control" = "192.168.0.50"
  }
}

##############################
# Network Infrastructure
##############################
resource "openstack_networking_network_v2" "private_network" {
  name = "task-network"
}

resource "openstack_networking_subnet_v2" "private_subnet" {
  name       = "task-subnet"
  network_id = openstack_networking_network_v2.private_network.id
  cidr       = "192.168.0.0/24"
  dns_nameservers = ["8.8.8.8"]
}

resource "openstack_networking_router_v2" "router" {
  name                = "task-router"
  external_network_id = "83554642-6df5-4c7a-bf55-21bc74496109"
}

resource "openstack_networking_router_interface_v2" "router_interface" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.private_subnet.id
}

##############################
# Security Groups (SSH + HTTP + Stats + ICMP)
##############################
resource "openstack_networking_secgroup_v2" "sg" {
  name        = "task-sg"
  description = "Allow SSH, HTTP, Stats, ICMP"
}

resource "openstack_networking_secgroup_rule_v2" "rules" {
  # Добавляем 8080 для мониторинга HAProxy
  for_each          = toset(["22", "80", "8080"])
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.key
  port_range_max    = each.key
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.sg.id
}

resource "openstack_networking_secgroup_rule_v2" "icmp" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.sg.id
}

##############################
# Resources
##############################
resource "openstack_compute_keypair_v2" "ssh" {
  name       = "task-key"
  public_key = file("C:/Users/Nurzhan.Zhanbirbayev/Documents/PS/pscloud_key.pub")
}

resource "openstack_blockstorage_volume_v3" "volumes" {
  for_each    = var.vms
  name        = "vol-${each.key}"
  size        = 20
  image_id    = var.image_id
  volume_type = "ceph-ssd"
}

resource "openstack_networking_port_v2" "ports" {
  for_each       = var.vms
  name           = "port-${each.key}"
  network_id     = openstack_networking_network_v2.private_network.id
  security_group_ids = [openstack_networking_secgroup_v2.sg.id]
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.private_subnet.id
    ip_address = each.value
  }
}

resource "openstack_compute_instance_v2" "instances" {
  for_each    = var.vms
  name        = each.key
  flavor_name = "d1.ram2cpu1"
  key_pair    = openstack_compute_keypair_v2.ssh.name

  network {
    port = openstack_networking_port_v2.ports[each.key].id
  }

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.volumes[each.key].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = true
  }

  user_data = each.key == "control" ? "#!/bin/bash\nyum install -y epel-release\nyum install -y ansible git" : null
}

##############################
# Floating IPs
##############################
resource "openstack_networking_floatingip_v2" "fips" {
  for_each = toset(["haproxy", "control"])
  pool     = "FloatingIP Net"
}

resource "openstack_networking_floatingip_associate_v2" "fip_assoc" {
  for_each    = toset(["haproxy", "control"])
  floating_ip = openstack_networking_floatingip_v2.fips[each.key].address
  port_id     = openstack_networking_port_v2.ports[each.key].id
}

##############################
# Ansible Execution
##############################
locals {
  control_public_ip = openstack_networking_floatingip_v2.fips["control"].address
}

resource "terraform_data" "run_ansible" {
  depends_on = [
    openstack_compute_instance_v2.instances,
    openstack_networking_floatingip_associate_v2.fip_assoc
  ]

  triggers_replace = {
    control_ip = local.control_public_ip
    # Хешируем файлы: если они изменятся на ПК, Terraform перезапустит Ansible
    hosts_hash = filemd5("${path.module}/ansible/hosts.ini")
    site_hash  = filemd5("${path.module}/ansible/site.yml")
  }

  connection {
    type        = "ssh"
    host        = local.control_public_ip
    user        = "centos"
    private_key = file(var.private_key_path)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p /home/centos/ansible",
      "chmod 700 /home/centos"
    ]
  }

  provisioner "file" {
    source      = "${path.module}/ansible/hosts.ini"
    destination = "/home/centos/ansible/hosts.ini"
  }

  provisioner "file" {
    source      = "${path.module}/ansible/site.yml"
    destination = "/home/centos/ansible/site.yml"
  }

  provisioner "file" {
    source      = var.private_key_path
    destination = "/home/centos/id_rsa"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod 600 /home/centos/id_rsa",
      "sudo yum install -y epel-release || true",
      "sudo yum install -y ansible git curl tar || true",
      "cd /home/centos/ansible",
      "ansible-playbook -i hosts.ini site.yml"
    ]
  }
}

##############################
# Outputs
##############################
output "haproxy_public_ip" {
  value = openstack_networking_floatingip_v2.fips["haproxy"].address
}

output "control_public_ip" {
  value = local.control_public_ip
}
