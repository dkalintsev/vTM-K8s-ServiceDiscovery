#
# Copyright (c) 2018 Pulse Secure LLC.
#
# Declaration of the vTM connection - this is the vTM instance that
# this template witll be applied to. It can be any vTM in a cluster.
#
provider "vtm" {
  base_url        = "https://${var.vtm_rest_ip}:${var.vtm_rest_port}/api"
  username        = "${var.vtm_username}"
  password        = "${var.vtm_password}"
  verify_ssl_cert = false
  version         = "~> 5.2.0"
}

# Random string for to make sure each deployment of this template
# includes unique string in all resources' names. This should allow
# deployment of more than one copy of this template to the same vTM
# cluster; as long as the unique things like IP addreses used for
# Traffic IP Groups are taken care of elsewhere.
#
resource "random_string" "instance_id" {
  length = 4

  special = false
  upper   = false
}

locals {
  # Create a local var with the value of the random instance_id
  uniq_id = "${random_string.instance_id.result}"
}

resource "vtm_extra_file" "kubeconf" {
  name    = "${local.uniq_id}-kubeconf"
  content = "${file("${path.module}/files/my-kubeconf")}"
}

resource "vtm_servicediscovery" "k8s-plugin" {
  name    = "${local.uniq_id}-K8s_nodeport.sh"
  content = "${file("${path.module}/files/K8s-get-nodeport-ips.sh")}"
}

# Pool automatically populated by K8s Service Discovery
resource "vtm_pool" "k8s_nodes" {
  name                          = "${local.uniq_id}_k8s-nodes"
  monitors                      = ["Ping"]
  service_discovery_enabled     = "true"
  service_discovery_interval    = "15"
  service_discovery_plugin      = "${vtm_servicediscovery.k8s-plugin.name}"
  service_discovery_plugin_args = "-s ${var.k8s-service-name} -c ${vtm_extra_file.kubeconf.name} -g"
}

# The Virtual Server
#
resource "vtm_virtual_server" "vs1" {
  name          = "${local.uniq_id}_VS1"
  enabled       = "true"
  listen_on_any = "true"
  pool          = "${vtm_pool.k8s_nodes.name}"
  port          = "80"
  protocol      = "http"
}
