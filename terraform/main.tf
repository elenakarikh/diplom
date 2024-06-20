terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.13"
    }
  }
}

variable "yandex_cloud_token" {
  type = string
}

provider "yandex" {
  token     = var.yandex_cloud_token
  cloud_id  = "b1gpv6u3h36g7impb908"
  folder_id = "b1gmlttm66sbucm9033f"
  zone      = "ru-central1-a"
}

# Создаю сеть
resource "yandex_vpc_network" "bastion-network" {
  name = "bastion-network"
}

# Подсеть, внутренняя-a
resource "yandex_vpc_subnet" "bastion-web1" {
  name           = "bastion-web1"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.bastion-network.id
  v4_cidr_blocks = ["192.168.1.0/24"]
  route_table_id = yandex_vpc_route_table.rout.id
}

# Подсеть, внутренняя-b
resource "yandex_vpc_subnet" "bastion-web2" {
  name           = "bastion-web2"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.bastion-network.id
  v4_cidr_blocks = ["192.168.2.0/24"]
  route_table_id = yandex_vpc_route_table.rout.id
}

# Подсеть, внешняя-a
resource "yandex_vpc_subnet" "bastion-ext" {
  name           = "bastion-ext"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.bastion-network.id
  v4_cidr_blocks = ["192.168.3.0/24"]
}

# Подсеть, внешняя-b
resource "yandex_vpc_subnet" "bastion-balans" {
  name           = "bastion-balans"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.bastion-network.id
  v4_cidr_blocks = ["192.168.4.0/24"]
}

resource "yandex_vpc_gateway" "nat_gateway" {
  name = "nat-gateway"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "rout" {
  name       = "rout"
  network_id = yandex_vpc_network.bastion-network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.nat_gateway.id
  }
}

#****************************************************************************************************
# Создаю группы безопасности
# Внутренний локальный
resource "yandex_vpc_security_group" "internal-sg" {
  name                = "internal-sg"
  description         = "Внутренний локальный"
  network_id          = yandex_vpc_network.bastion-network.id

  ingress {
    protocol          = "any"
    description       = "Разрешает взаимодействие между ресурсами текущей группы безопасности"
    predefined_target = "self_security_group"
    from_port         = 0
    to_port           = 65535
  }

  egress {
    description       = "Исходящий трафик на любой порт"
    protocol          = "any"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    from_port         = 0
    to_port           = 65535
  }
}

# Внешний для ssh
resource "yandex_vpc_security_group" "external-ssh-sg" {
  name                = "external-ssh-sg"
  description         = "Внешний для ssh"
  network_id          = yandex_vpc_network.bastion-network.id

  ingress {
    description       = "Входящий трафик TCP, с любого адреса, на порт 22"
    protocol          = "tcp"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    port              = 22
  }

  ingress {
    description       = "Входящий трафик allow ping"
    protocol          = "ICMP"
    v4_cidr_blocks    = ["0.0.0.0/0"]
  }

  ingress {
    description       = "Входящий трафик TCP, из локального ssh, на порт 22"
    protocol          = "tcp"
    security_group_id = yandex_vpc_security_group.internal-sg.id
    port              = 22
  }

  egress {
    description       = "Исходящий трафик любой, на любой адрес, на любой порт"
    protocol          = "any"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    from_port         = 0
    to_port           = 65535
  }
}

#Kibana server SG
resource "yandex_vpc_security_group" "kibana-sg" {
  name        = "kibana-sg"
  network_id  = yandex_vpc_network.bastion-network.id

  ingress {
    protocol       = "tcp"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 5601
  }
  ingress {
    protocol       = "ICMP"
    description    = "allow ping"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol       = "ANY"
    description    = "allow any outgoing connection"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Zabbix server SG
resource "yandex_vpc_security_group" "zabbix-server-sg" {
  name        = "zabbix-server-sg"
  network_id  = yandex_vpc_network.bastion-network.id

  ingress {
    protocol          = "tcp"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    port              = 80
  }

  ingress {
    protocol          = "tcp"
    v4_cidr_blocks    = yandex_vpc_subnet.bastion-ext.v4_cidr_blocks
    from_port         = 10050
    to_port           = 10052
  }

  ingress {
    protocol          = "tcp"
    v4_cidr_blocks    = yandex_vpc_subnet.bastion-web1.v4_cidr_blocks
    from_port         = 10050
    to_port           = 10051
  }

  ingress {
    protocol          = "tcp"
    v4_cidr_blocks    = yandex_vpc_subnet.bastion-web2.v4_cidr_blocks
    from_port         = 10050
    to_port           = 10051
  }

  ingress {
    protocol       = "ICMP"
    description    = "allow ping"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol       = "ANY"
    description    = "allow any outgoing connection"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# На Балансировщик SG
resource "yandex_vpc_security_group" "alb-sg" {
  name                = "alb-sg"
  network_id          = yandex_vpc_network.bastion-network.id

  ingress {
    protocol          = "tcp"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    port              = 80
  }

  ingress {
    description       = "health checks"
    protocol          = "any"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    predefined_target = "loadbalancer_healthchecks"
  }
  
  egress {
    protocol          = "ANY"
    description       = "allow any outgoing connection"
    v4_cidr_blocks    = ["0.0.0.0/0"]
  }
}

#******************************************************************************
# Создаю ВМ, web1
resource "yandex_compute_instance" "web1" {
  name = "web1"
  hostname = "web1"
  zone = "ru-central1-a"
  allow_stopping_for_update = true

  resources {
    core_fraction = 20
    cores         = 2
    memory        = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8la94d0qhv8eadc3tn"
      size     = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.bastion-web1.id
      dns_record {
      fqdn = "web1.srv."
      ttl = 300
      }
    security_group_ids = [
                           yandex_vpc_security_group.internal-sg.id,
                           yandex_vpc_security_group.alb-sg.id,
                           yandex_vpc_security_group.zabbix-server-sg.id
                         ]
    nat       = false
    ip_address = "192.168.1.10"
  }

  metadata = {
    user-data = "${file("./meta.yml")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

# web2
resource "yandex_compute_instance" "web2" {
  name = "web2"
  hostname = "web2"
  zone = "ru-central1-b"
  allow_stopping_for_update = true

  resources {
    core_fraction = 20
    cores         = 2
    memory        = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8la94d0qhv8eadc3tn"
      size     = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.bastion-web2.id
      dns_record {
      fqdn = "web2.srv."
      ttl = 300
      }
    security_group_ids = [
                           yandex_vpc_security_group.internal-sg.id,
                           yandex_vpc_security_group.alb-sg.id,
                           yandex_vpc_security_group.zabbix-server-sg.id
                         ]
    nat       = false
    ip_address = "192.168.2.10"
  }

  metadata = {
    user-data = "${file("./meta.yml")}"
  }

    scheduling_policy {
    preemptible = true
  }
}

# ВМ Бастион хост
resource "yandex_compute_instance" "bastion" {
  name     = "bastion"
  hostname = "bastion"
  zone     = "ru-central1-a"
  allow_stopping_for_update = true

  resources {
    core_fraction = 20
    cores         = 2
    memory        = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8la94d0qhv8eadc3tn"
      size     = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.bastion-ext.id
      dns_record {
      fqdn = "bastion.srv."
      ttl = 300
      }
    security_group_ids = [
                          yandex_vpc_security_group.external-ssh-sg.id,
                          yandex_vpc_security_group.internal-sg.id,
                          yandex_vpc_security_group.zabbix-server-sg.id,
                          yandex_vpc_security_group.kibana-sg.id
                        ]

    nat        = true
    ip_address = "192.168.3.10"
  }

  metadata = {
    user-data = "${file("./meta.yml")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

# ВМ Zabbix-server
resource "yandex_compute_instance" "zabbix-server" {
  name                      = "zabbix-server"
  hostname                  = "zabbix-server"
  zone                      = "ru-central1-a"
  allow_stopping_for_update = true

  resources {
    core_fraction = 20
    cores         = 2
    memory        = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8la94d0qhv8eadc3tn"
      size     = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.bastion-ext.id
      dns_record {
      fqdn = "zabbix.srv."
      ttl = 300
      }
    security_group_ids = [
                           yandex_vpc_security_group.internal-sg.id,
                           yandex_vpc_security_group.external-ssh-sg.id,
                           yandex_vpc_security_group.zabbix-server-sg.id
                         ]

    nat        = true
    ip_address = "192.168.3.20"
  }

  metadata = {
    user-data = "${file("./meta.yml")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

# ВМ Elasticsearch
resource "yandex_compute_instance" "elasticsearch" {
  name = "elasticsearch"
  hostname = "elasticsearch"
  zone = "ru-central1-b"
  allow_stopping_for_update = true

  resources {
    core_fraction = 20
    cores         = 2
    memory        = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8la94d0qhv8eadc3tn"
      size     = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.bastion-web2.id
      dns_record {
      fqdn = "elasticsearch.srv."
      ttl = 300
      }
    security_group_ids = [
                           yandex_vpc_security_group.internal-sg.id,
                           yandex_vpc_security_group.external-ssh-sg.id,
                           yandex_vpc_security_group.zabbix-server-sg.id
                         ]
    nat       = false
    ip_address = "192.168.2.30"
  }

  metadata = {
    user-data = "${file("./meta.yml")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

# ВМ Kibana
resource "yandex_compute_instance" "kibana" {
  name          = "kibana"
  hostname      = "kibana"
  zone          = "ru-central1-a"
  allow_stopping_for_update = true

  resources {
    core_fraction = 20
    cores         = 2
    memory        = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8la94d0qhv8eadc3tn"
      size     = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.bastion-ext.id
      dns_record {
      fqdn = "kibana.srv."
      ttl = 300
      }
    security_group_ids = [
                           yandex_vpc_security_group.internal-sg.id,
                           yandex_vpc_security_group.external-ssh-sg.id,
                           yandex_vpc_security_group.zabbix-server-sg.id,
                           yandex_vpc_security_group.kibana-sg.id
                         ]

    nat        = true
    ip_address = "192.168.3.30"
  }

  metadata = {
    user-data = "${file("./meta.yml")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

#**************************************************************************************
#Таргет группа
resource "yandex_alb_target_group" "tg-web" {
  name = "tg-web"

  target {
    subnet_id  = yandex_vpc_subnet.bastion-web1.id
    ip_address = yandex_compute_instance.web1.network_interface.0.ip_address
  }

  target {
    subnet_id  = yandex_vpc_subnet.bastion-web2.id
    ip_address = yandex_compute_instance.web2.network_interface.0.ip_address
  }
}

# Создаю группу бэкендов
resource "yandex_alb_backend_group" "bg" {
  name                     = "web-bg"
  
  http_backend {
    name                   = "http-backend"
    weight                 = 1
    port                   = 80
    target_group_ids       = [yandex_alb_target_group.tg-web.id]
    load_balancing_config {
      panic_threshold      = 90
    }    
    healthcheck {
      timeout              = "10s"
      interval             = "2s"
      healthy_threshold    = 10
      healthcheck_port     = 80
      unhealthy_threshold  = 15 
      http_healthcheck {
        path               = "/"
      }
    }
  }
}

# HTTP-роутер для HTTP-трафика и виртуальный хост
resource "yandex_alb_http_router" "tf-router" {
  name          = "tf-router"
}

resource "yandex_alb_virtual_host" "virtualhost" {
  name                    = "virtualhost"
  http_router_id          = yandex_alb_http_router.tf-router.id
  route {
    name                  = "route"
    http_route {
      http_route_action {
        backend_group_id  = yandex_alb_backend_group.bg.id
        timeout           = "60s"
      }
    }
  }
}

# L7-балансировщик
resource "yandex_alb_load_balancer" "alblb" {
  name        = "alblb"
  network_id  = yandex_vpc_network.bastion-network.id
  security_group_ids = [yandex_vpc_security_group.alb-sg.id,
                        yandex_vpc_security_group.external-ssh-sg.id,
                        yandex_vpc_security_group.internal-sg.id]

  allocation_policy {
    location {
      zone_id   = "ru-central1-b"
      subnet_id = yandex_vpc_subnet.bastion-balans.id
    }
  }

  listener {
    name        = "list"
    endpoint {
      address {
        external_ipv4_address {
        }
      }
      ports = [ 80 ]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.tf-router.id
      }
    }
  }

  log_options {
    discard_rule {
      http_code_intervals = ["HTTP_2XX"]
      discard_percent     = 75
    }
  }
}

#***************************************************************************************
# Вывести ip-адреса, Bastion host
output "bastion_nat" {
  value = yandex_compute_instance.bastion.network_interface.0.nat_ip_address
}
output "bastion" {
  value = yandex_compute_instance.bastion.network_interface.0.ip_address
}
output "FQDN_bastion" {
  value = yandex_compute_instance.bastion.fqdn
}

# Вэбсервер - 1
output "web1" {
  value = yandex_compute_instance.web1.network_interface.0.ip_address
}
output "FQDN_web1" {
  value = yandex_compute_instance.web1.fqdn
}

# Вэбсервер - 2
output "web2" {
  value = yandex_compute_instance.web2.network_interface.0.ip_address
}
output "FQDN_web2" {
  value = yandex_compute_instance.web2.fqdn
}

# kibana
output "kibana-nat" {
  value = yandex_compute_instance.kibana.network_interface.0.nat_ip_address
}
output "kibana" {
  value = yandex_compute_instance.kibana.network_interface.0.ip_address
}
output "FQDN_kibana" {
  value = yandex_compute_instance.kibana.fqdn
}

# zabbix-сервер
output "zabbix_nat" {
  value = yandex_compute_instance.zabbix-server.network_interface.0.nat_ip_address
}
output "zabbix" {
  value = yandex_compute_instance.zabbix-server.network_interface.0.ip_address
}
output "FQDN_zabbix" {
  value = yandex_compute_instance.zabbix-server.fqdn
}

# elasticsearch
output "elasticsearch" {
  value = yandex_compute_instance.elasticsearch.network_interface.0.ip_address
}
output "FQDN_elasticsearch" {
  value = yandex_compute_instance.elasticsearch.fqdn
}

# Балансировщик
output "load_balancer_pub" {
  value = yandex_alb_load_balancer.alblb.listener[0].endpoint[0].address[0].external_ipv4_address
}

#**************************************************************************************************
resource "yandex_compute_snapshot_schedule" "snapshot" {
  name = "snapshot"

  schedule_policy {
    expression = "0 10 ? * *"
  }

  retention_period = "168h"
  snapshot_count = 7
  snapshot_spec {
    description = "daily-snapshot"
  }

  disk_ids = [
    "${yandex_compute_instance.bastion.boot_disk.0.disk_id}",
    "${yandex_compute_instance.web1.boot_disk.0.disk_id}",
    "${yandex_compute_instance.web2.boot_disk.0.disk_id}",
    "${yandex_compute_instance.zabbix-server.boot_disk.0.disk_id}",
    "${yandex_compute_instance.elasticsearch.boot_disk.0.disk_id}",
    "${yandex_compute_instance.kibana.boot_disk.0.disk_id}", ]
}

#**********************************************************************************************
# Формирую hosts.ini 
resource "local_file" "ansible_inventory" {
  content  = <<-EOT
    [web_servers]
    web1 ansible_host=${yandex_compute_instance.web1.fqdn}
    web2 ansible_host=${yandex_compute_instance.web2.fqdn}

    [web_server_1]
    web1 ansible_host=${yandex_compute_instance.web1.fqdn}

    [web_server_2]
    web2 ansible_host=${yandex_compute_instance.web2.fqdn}

    [zabbix_server]
    zabbix ansible_host=${yandex_compute_instance.zabbix-server.fqdn}

    [elastic_server]
    elasticsearch ansible_host=${yandex_compute_instance.elasticsearch.fqdn}

    [kibana_server]
    kibana ansible_host=${yandex_compute_instance.kibana.fqdn}

    [bastion_server]
    bastion ansible_host=${yandex_compute_instance.bastion.network_interface.0.ip_address}

    [all:vars]
    ansible_user=ekarih
    ansible_ssh_private_key_file=/home/ekarih/.ssh/id_rsa
    ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyCommand="ssh -p 22 -W %h:%p -q ekarih@${yandex_compute_instance.bastion.network_interface.0.nat_ip_address}"'
    
    EOT
  filename = "../ansible/hosts.ini"
}