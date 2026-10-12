# ECS 클러스터와 서비스의 state는 기존 v1 state 버킷에 별도 key로 저장한다.
terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v1"
    key          = "ecs/terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
