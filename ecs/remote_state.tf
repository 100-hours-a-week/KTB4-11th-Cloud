# 참조 방향은 ecs → shared-infra / app-server 단방향으로만 유지한다.
# shared-infra, app-server는 ecs를 참조하지 않는다.

# VPC, Private Subnet
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "shared-infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# ALB 리스너, Blue Target Group, ALB·V1 앱 Security Group, DB 이관 호스트
data "terraform_remote_state" "app" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "app-server/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# 운영 Valkey 엔드포인트, 서비스별 사용자·Connect Policy, Valkey SG
data "terraform_remote_state" "redis" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-redis"
    key    = "redis/prod/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# SQS replay queue and the dedicated producer policy for the V2 Backend.
data "terraform_remote_state" "messaging_prod" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-sqs"
    key    = "messaging/prod/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# V1 AI 운영 서버 (market 서비스가 읽는 QuestDB·PostgreSQL 호스트)
# TODO: V2 데이터 저장소로 이전하면 이 참조와 cross_root_rules.tf의 AI SG 규칙을 함께 제거
data "terraform_remote_state" "ai" {
  backend = "s3"

  config = {
    bucket = "stockspoon-terraform-state-v1"
    key    = "ai-server/infra/terraform.tfstate"
    region = "ap-northeast-2"
  }
}
