variable "kubeconfig_path" {
  description = "Kubeconfig for the externally created local kind cluster."
  type        = string
}

variable "namespace" {
  description = "Dedicated local demonstration namespace."
  type        = string
  default     = "tesl-rolling"
}

variable "app_image" {
  description = "Immutable revision tag already loaded into kind."
  type        = string
}

variable "revision" {
  description = "Positive integer application revision."
  type        = number
  validation {
    condition     = var.revision >= 1 && floor(var.revision) == var.revision
    error_message = "revision must be a positive integer."
  }
}

variable "schema_version" {
  description = "Positive integer schema version compiled into the image (annotation only)."
  type        = number
  validation {
    condition     = var.schema_version >= 1 && floor(var.schema_version) == var.schema_version
    error_message = "schema_version must be a positive integer."
  }
}

variable "host_port" {
  description = "Host port mapped externally by kind to NodePort 30080; output only."
  type        = number
  default     = 8080
}
