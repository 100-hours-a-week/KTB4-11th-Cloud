# Policy documents are rendered locally by the provider; no AWS API is used.
provider "aws" {
  region                      = "ap-northeast-2"
  access_key                  = "offline-test"
  secret_key                  = "offline-test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

variables {
  resource_arns = {
    backend_rollback_parameter       = "arn:aws:ssm:ap-northeast-2:250832562715:parameter/test"
    backend_datasource_url_parameter = "arn:aws:ssm:ap-northeast-2:250832562715:parameter/test-url"
    alb_logs                         = "arn:aws:s3:::test-logs"
    stock_logos                      = "arn:aws:s3:::test-logos"
    frontend_assets                  = "arn:aws:s3:::test-assets"
    cloudfront_distributions         = "arn:aws:cloudfront::250832562715:distribution/*"
    lambda                           = ["arn:aws:lambda:ap-northeast-2:250832562715:function:test"]
    secrets                          = ["arn:aws:secretsmanager:ap-northeast-2:250832562715:secret:test"]
    queues                           = ["arn:aws:sqs:ap-northeast-2:250832562715:test"]
    ecr_public                       = ["arn:aws:ecr-public::250832562715:repository/test"]
    ecr_private                      = ["arn:aws:ecr:ap-northeast-2:250832562715:repository/test"]
    ses                              = ["arn:aws:ses:ap-northeast-2:250832562715:identity/test"]
    iam_resources                    = ["arn:aws:iam::250832562715:role/test"]
    iam_accounts                     = ["arn:aws:iam::250832562715:user/test"]
    pass_roles                       = ["arn:aws:iam::250832562715:role/test"]
    hosted_zone                      = "arn:aws:route53:::hostedzone/test"
  }
  fis_resource_arns = {
    roles = [
      "arn:aws:iam::250832562715:role/stockspoon-market-http-fis01",
      "arn:aws:iam::250832562715:role/stockspoon-market-http-fis-redis",
    ]
    templates = "arn:aws:fis:ap-northeast-2:250832562715:experiment-template/*"
    actions   = "arn:aws:fis:ap-northeast-2:*:action/*"
  }
}

run "template_deployment_permissions" {
  command = plan

  assert {
    condition = alltrue([
      for document in values(output.documents) :
      !strcontains(document, "fis:StartExperiment") && !strcontains(document, "fis:StopExperiment") && !strcontains(document, "fis:*")
    ])
    error_message = "CI must not receive FIS experiment execution permissions."
  }
  assert {
    condition = alltrue([
      for statement in jsondecode(output.documents.compute).Statement :
      statement.Sid != "PassExperimentRolesToFis" ? true : (
        toset(statement.Resource) == toset(var.fis_resource_arns.roles) &&
        statement.Condition.StringEquals["iam:PassedToService"] == "fis.amazonaws.com"
      )
    ])
    error_message = "FIS PassRole must be limited to the two experiment roles and FIS service."
  }
  assert {
    condition = alltrue([
      for document in values(output.documents) : length(jsonencode(jsondecode(document))) <= 6144
    ])
    error_message = "Managed policies must stay within the IAM policy size limit."
  }
  assert {
    condition = toset(flatten([
      for statement in jsondecode(output.documents.compute).Statement :
      statement.Sid == "ManageFisTemplatesOnly" ? tolist(statement.Action) : []
      ])) == toset([
      "fis:CreateExperimentTemplate", "fis:UpdateExperimentTemplate",
      "fis:DeleteExperimentTemplate", "fis:TagResource", "fis:UntagResource",
    ])
    error_message = "Template management actions must be present."
  }
}

run "existing_callers_without_fis_scopes" {
  command = plan
  variables {
    fis_resource_arns = null
  }
  assert {
    condition     = !strcontains(output.documents.compute, "fis:")
    error_message = "Existing module callers must not acquire FIS permissions by default."
  }
}
