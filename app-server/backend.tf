# Terraform 상태 파일(tfstate)을 S3에 저장하여
# 팀원 간 동일한 인프라 상태를 공유하고, 동시 변경 시 충돌을 방지한다.
# Terraform 공식 문서 : Backend = Terraform state를 어디에 저장하고 어떻게 잠글지 결정하는 구성

terraform {
  backend "s3" {
    bucket       = "stockspoon-terraform-state-v1"
    key          = "terraform.tfstate"
    region       = "ap-northeast-2"
    use_lockfile = true
    encrypt      = true
  }
}
