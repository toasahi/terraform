variable "name" {
  description = "Alias name for the key (without the alias/ prefix)."
  type        = string
}

variable "description" {
  description = "Human readable description of the key."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Waiting period before the key is deleted after a destroy."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to the key."
  type        = map(string)
  default     = {}
}
