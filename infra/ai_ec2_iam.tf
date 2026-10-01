# AI 전용 EC2가 AWS API를 호출할 수 있도록 하는 역할
# 이 역할은 EC2 인스턴스에서만 AssumeRole 할 수 있게 허용한다
resource "aws_iam_role" "ai_ec2" {
  name = "stockspoon-v1-ai-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "stockspoon-v1-ai-ec2-role"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# AI EC2가 Tailscale 인증 키를 SSM에서 읽을 수 있도록 제한된 권한 부여
# 특정 파라미터 경로만 접근 허용하여 다른 SSM 값은 읽지 못하게 한다
resource "aws_iam_policy" "ai_ssm_get_parameter" {
  name = "stockspoon-v1-ai-ssm-get-parameter"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:ap-northeast-2:*:parameter/stockspoon/ai/tailscale-auth-key"
      }
    ]
  })

  tags = {
    Name        = "stockspoon-v1-ai-ssm-get-parameter"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}

# 위 정책을 AI EC2 역할에 연결
resource "aws_iam_role_policy_attachment" "ai_ssm_get_parameter" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = aws_iam_policy.ai_ssm_get_parameter.arn
}

# AI 알람 Lambda가 SSM Run Command로 docker stats를 조회할 수 있도록
# AI EC2를 Systems Manager 관리형 인스턴스로 등록한다.
resource "aws_iam_role_policy_attachment" "ai_ssm_managed_instance" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2 인스턴스에 붙이는 프로필
# 이 프로필을 AI EC2 인스턴스에 연결하면, 인스턴스 내부에서 AWS CLI가 역할을 사용
resource "aws_iam_instance_profile" "ai_ec2" {
  name = "stockspoon-v1-ai-instance-profile"
  role = aws_iam_role.ai_ec2.name

  tags = {
    Name        = "stockspoon-v1-ai-instance-profile"
    Project     = "stockspoon"
    Environment = "v1"
    ManagedBy   = "Terraform"
  }
}
