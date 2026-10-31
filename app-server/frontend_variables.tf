variable "frontend_edge_enabled" {
  description = "Create the V2 CloudFront/S3 infrastructure before a separate DNS cutover"
  type        = bool
  default     = true
}

variable "frontend_assets_ready" {
  description = "Route /_next/static/* to S3 only after uploading assets from the production image"
  type        = bool
  default     = true

  validation {
    condition     = !var.frontend_assets_ready || var.frontend_edge_enabled
    error_message = "Enable frontend_edge_enabled before routing assets to S3."
  }
}

variable "frontend_v2_origin_ready" {
  description = "Send page requests to the V2 ECS listener rule after verifying healthy frontend tasks"
  type        = bool
  default     = true

  validation {
    condition     = !var.frontend_v2_origin_ready || var.frontend_edge_enabled
    error_message = "Enable frontend_edge_enabled before enabling the V2 origin."
  }
}

variable "frontend_price_class" {
  description = "PriceClass_All includes Seoul; PriceClass_100 excludes Asian edge locations"
  type        = string
  default     = "PriceClass_All"

  validation {
    condition     = contains(["PriceClass_All", "PriceClass_200", "PriceClass_100"], var.frontend_price_class)
    error_message = "Use a supported CloudFront price class."
  }
}

variable "frontend_deployment_branch" {
  description = "FE V2 production branch authorized by the publish and ECS deployment roles"
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*$", var.frontend_deployment_branch))
    error_message = "Provide a literal branch name, without refs/heads/ or wildcard characters."
  }
}

locals {
  frontend_deploy_github_subject = "repo:100-hours-a-week@167328634/KTB4-11th-FE@1352298546:ref:refs/heads/${var.frontend_deployment_branch}"
}

output "frontend_deployment_contract" {
  description = "Shared FE deployment branch/subject for ECS; CD jobs must not use an environment-based OIDC subject"
  value = {
    branch       = var.frontend_deployment_branch
    oidc_subject = local.frontend_deploy_github_subject
  }
}
