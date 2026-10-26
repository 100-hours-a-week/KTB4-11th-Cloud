# Private ECR 저장소
# 환경별로 저장소를 나눠, 개발 CI가 운영 저장소에 push하지 못하도록 권한을 분리한다.
# 이미지 레이어는 Private Subnet의 S3 Gateway Endpoint를 통해 내려받아 NAT 데이터 처리 비용을 줄인다.
resource "aws_ecr_repository" "this" {
  for_each = var.repository_names

  name = each.value

  # 같은 태그로 다른 이미지를 덮어쓰지 못하게 한다.
  # 배포 CI는 git SHA처럼 매번 다른 태그를 사용해야 한다.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
