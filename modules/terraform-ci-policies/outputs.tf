output "documents" {
  description = "Policy JSON documents; IAM policies and attachments remain owned by app-server"
  value = {
    compute       = data.aws_iam_policy_document.terraform_ci_write_compute.json
    application   = data.aws_iam_policy_document.terraform_ci_write_application.json
    observability = data.aws_iam_policy_document.terraform_ci_write_observability.json
    identity      = data.aws_iam_policy_document.terraform_ci_write_identity.json
    api_waf       = data.aws_iam_policy_document.terraform_ci_write_api_waf.json
    edge          = data.aws_iam_policy_document.terraform_ci_write_edge.json
  }
}
