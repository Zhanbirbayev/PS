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

# Описание 5 серверов
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
  dns_nameservers = ["195.210.46.195", "195.210.46.132"]
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
# Security Groups (SSH + HTTP + ICMP)
##############################
resource "openstack_networking_secgroup_v2" "sg" {
  name        = "task-sg"
  description = "Allow SSH, HTTP, ICMP"
}

resource "openstack_networking_secgroup_rule_v2" "rules" {
  for_each          = toset(["22", "80"])
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

# Создаем 5 дисков
resource "openstack_blockstorage_volume_v3" "volumes" {
  for_each    = var.vms
  name        = "vol-${each.key}"
  size        = 20
  image_id    = var.image_id
  volume_type = "ceph-ssd"
}

# Создаем 5 портов с фиксированными IP
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

# Создаем 5 инстансов
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

  # Скрипт только для Control Node: установка Ansible
  user_data = each.key == "control" ? "#!/bin/bash\nyum install -y epel-release\nyum install -y ansible git" : null
}

##############################
# Floating IPs (Для HAProxy и Control)
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

output "haproxy_public_ip" {
  value = openstack_networking_floatingip_v2.fips["haproxy"].address
}

output "control_public_ip" {
  value = openstack_networking_floatingip_v2.fips["control"].address
}
