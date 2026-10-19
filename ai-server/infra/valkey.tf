# V1 AI 운영 EC2 → V2 운영 Valkey 접근 허용
# AI EC2는 shared-infra Public Subnet에 있어 redis@prod의 Private Subnet CIDR 규칙에 포함되지 않는다.
# Public Subnet CIDR 전체를 열지 않고 AI Security Group만 허용하며, 접속 통제는 AI 전용 IAM 사용자가 담당한다.
# TODO: AI market 서비스가 V2(ECS)로 이전되면 이 파일과 redis@prod의 ai 사용자를 함께 제거

locals {
  valkey_security_group_id = data.terraform_remote_state.redis_prod.outputs.valkey_security_group_id
}

# 기본(쓰기·읽기) 엔드포인트
resource "aws_vpc_security_group_ingress_rule" "valkey_from_ai" {
  security_group_id            = local.valkey_security_group_id
  referenced_security_group_id = aws_security_group.ai.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Allow the V1 production AI host to connect to Valkey over TLS"
}

# Serverless 읽기 엔드포인트. 클라이언트가 클러스터 토폴로지 갱신 중 연결할 수 있다.
resource "aws_vpc_security_group_ingress_rule" "valkey_reader_from_ai" {
  security_group_id            = local.valkey_security_group_id
  referenced_security_group_id = aws_security_group.ai.id
  from_port                    = 6380
  to_port                      = 6380
  ip_protocol                  = "tcp"
  description                  = "Allow the V1 production AI host to connect to the Valkey reader endpoint"
}

# AI EC2 Role이 stockspoon-v2-prod-valkey-ai 사용자로만 IAM 인증 접속할 수 있게 한다.
resource "aws_iam_role_policy_attachment" "ai_valkey_connect" {
  role       = aws_iam_role.ai_ec2.name
  policy_arn = data.terraform_remote_state.redis_prod.outputs.valkey_connect_policy_arns["ai"]
}
