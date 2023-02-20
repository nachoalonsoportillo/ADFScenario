variable "resource_groups_prefix" {
  type        = string
  description = "String to use as a prefix for all resource group names."
  default     = "rg"
}

variable "location" {
  type        = string
  description = "Location."
  default     = "westeurope"
}

variable "adls_filesystems" {
  type        = map(string)
  description = "List of file systems."
  default = {
    input_copy   = "input-copy"
    output_copy   = "output-copy"
    input_flow   = "input-flow"
    output_flow   = "output-flow"
  }
}