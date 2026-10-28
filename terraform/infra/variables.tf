variable "environment_name" {
  type        = string
  description = "The azd environment name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.environment_name))
    error_message = "Use 1-20 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "location" {
  type        = string
  description = "Azure region supporting Azure SRE Agent."
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription selected in azd."
}
