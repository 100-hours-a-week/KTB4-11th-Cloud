# AI 전용 EC2가 AWS API를 호출할 수 있도록 하는 역할입니다.
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

# AI EC2가 특정 Tailscale 인증 키만 SSM에서 읽을 수 있게 합니다.
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

resource "aws_iam_role_policy_attachment" "ai_ssm_get_parameter" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = aws_iam_policy.ai_ssm_get_parameter.arn
}

# AI 알람 Lambda가 SSM Run Command로 Docker 상태를 조회할 수 있게 합니다.
resource "aws_iam_role_policy_attachment" "ai_ssm_managed_instance" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

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
