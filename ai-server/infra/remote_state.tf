# VPC와 subnet은 워크로드와 분리된 shared-infra state가 관리합니다.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "shared-infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# AI API ingress에서 참조하는 App Security Group은 app-server가 관리합니다.
data "terraform_remote_state" "app" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "app-server/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# 운영 Valkey Security Group과 AI 전용 사용자·Connect Policy는 redis@prod가 관리합니다.
data "terraform_remote_state" "redis_prod" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-redis"
    key    = "redis/prod/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# 운영 SQS(주문 FIFO 큐, 리포트 요청 큐)와 AI 전용 SQS 정책은 messaging@prod가 관리합니다.
data "terraform_remote_state" "messaging_prod" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-sqs"
    key    = "messaging/prod/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
