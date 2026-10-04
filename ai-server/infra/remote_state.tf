# 공통 VPC, subnet, App Security Group은 기존 infra가 계속 관리합니다.
data "terraform_remote_state" "core" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# AI EC2 이전 후 사용할 최신 Ubuntu Server 26.04 LTS x86_64 AMI 조회입니다.
data "aws_ssm_parameter" "ubuntu_2604_ami" {
  name = "/aws/service/canonical/ubuntu/server/resolute/stable/current/amd64/hvm/ebs-gp3/ami-id"
}
