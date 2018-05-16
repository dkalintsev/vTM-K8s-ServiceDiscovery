variable "vtm_rest_ip" {
  description = "IP or FQDN of the vTM REST API endpoint, e.g. '192.168.0.1'"
}

variable "vtm_rest_port" {
  description = "TCP port of the vTM REST API endpoint"
  default     = "9070"
}

variable "vtm_username" {
  description = "Username to use for connecting to the vTM"
  default     = "admin"
}

variable "vtm_password" {
  description = "Password of the $vtm_username account on the vTM"
}

variable "k8s-service-name" {
  description = "Name of the K8s Service with a single nodePort to use for vTM pool nodes"
}
