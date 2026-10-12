# 컨테이너 이미지 저장소는 ECS와 수명이 다르므로 별도 state로 관리한다.
terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v2"
    key          = "ecr/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
