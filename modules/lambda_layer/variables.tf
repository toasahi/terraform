variable "name" {
  description = "Layer name."
  type        = string
}

variable "source_dir" {
  description = "Directory containing the layer content (must contain a python/ directory)."
  type        = string
}

variable "build_dir" {
  description = "Directory where the zip archive is written."
  type        = string
}

variable "compatible_runtimes" {
  description = "Lambda runtimes the layer is compatible with."
  type        = list(string)
  default     = ["python3.12"]
}
