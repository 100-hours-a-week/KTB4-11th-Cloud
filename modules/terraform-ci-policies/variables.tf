variable "resource_arns" {
  description = "Resource scopes supplied by the owning app-server root"
  type = object({
    backend_rollback_parameter       = string
    backend_datasource_url_parameter = string
    alb_logs                         = string
    stock_logos                      = string
    lambda                           = list(string)
    secrets                          = list(string)
    queues                           = list(string)
    ecr_public                       = list(string)
    ecr_private                      = list(string)
    ses                              = list(string)
    iam_resources                    = list(string)
    iam_accounts                     = list(string)
    pass_roles                       = list(string)
    hosted_zone                      = string
  })
}
