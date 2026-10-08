data "aws_vpc" "target" {
  id = data.terraform_remote_state.test.outputs.vpc_id
}
