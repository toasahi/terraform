variable "name" {
  description = "Name prefix for the API and related resources."
  type        = string
}

variable "stage_name" {
  description = "API Gateway stage name."
  type        = string
  default     = "live"
}

variable "ingress_queue" {
  description = "ingress.standard queue (arn, url, name)."
  type = object({
    arn  = string
    url  = string
    name = string
  })
}

variable "kms_key_arn" {
  description = "KMS key that encrypts the ingress queue, the log groups and the authorizer environment."
  type        = string
}

variable "authorizer_source_dir" {
  description = "Directory of the Lambda authorizer code."
  type        = string
}

variable "build_dir" {
  description = "Directory where Lambda zips are written."
  type        = string
}

variable "source_tokens_secret_arn" {
  description = "Secrets Manager secret holding a JSON object { \"<source>\": \"<token>\", ... } validated by the authorizer."
  type        = string
}

variable "throttling_rate_limit" {
  description = "Steady-state requests per second allowed on the stage."
  type        = number
  default     = 50
}

variable "throttling_burst_limit" {
  description = "Burst requests allowed on the stage."
  type        = number
  default     = 200
}

variable "domain_name" {
  description = "Custom domain name (public hosted zone) for the API."
  type        = string
}

variable "certificate_arn" {
  description = "Regional ACM certificate ARN for the custom domain."
  type        = string
}

variable "waf_rate_limit_per_5min" {
  description = "WAF rate-based rule: requests per 5 minutes per source IP before blocking."
  type        = number
  default     = 2000
}

variable "source_ip_allowlists" {
  description = "Per-source CIDR allow lists enforced by WAF, keyed by the {source} path segment. Sources not listed are only protected by the token. Example: { datadog = [\"1.2.3.0/24\"] }."
  type        = map(list(string))
  default     = {}
}

variable "manage_account_cloudwatch_role" {
  description = "Create the account-level API Gateway CloudWatch Logs role (one per account/region). Set false if it already exists."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention of access and execution logs."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
