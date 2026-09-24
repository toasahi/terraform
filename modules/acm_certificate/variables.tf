variable "domain_name" {
  description = "FQDN the certificate is issued for (e.g. alerts.example.com)."
  type        = string
}

variable "zone_id" {
  description = "Public hosted zone ID used for DNS validation."
  type        = string
}

variable "tags" {
  description = "Tags applied to the certificate."
  type        = map(string)
  default     = {}
}
