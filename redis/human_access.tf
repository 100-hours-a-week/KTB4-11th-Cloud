# 개발자 개인 Valkey 접근 (dev·prod 공통)
# 애플리케이션 사용자를 공유하지 않고 개인별 IAM 인증 사용자와 Connect Policy를 둬서
# 누가 데이터를 조회·수정했는지 구분할 수 있게 한다.
# 네트워크 경로는 각 환경의 AI EC2이며(dev: valkey_from_ai, prod: ai-server/infra/valkey.tf),
# 개발자는 AI EC2에서 자기 IAM 자격 증명(AWS_PROFILE 등)으로 토큰을 만들어 접속한다.
# 인스턴스 Role 자격 증명으로는 이 사용자의 Connect 권한이 없다.

locals {
  # key: IAM 사용자 이름(iam root가 관리하는 기존 사용자)
  human_users = {
    for name in ["ezra"] : name => "${local.name_prefix}-${name}"
  }

  # 키 조회·수정만 허용하고 FLUSHALL·KEYS·CONFIG·INFO 등 위험 명령은 차단한다.
  # +@connection은 PING·HELLO 등 클라이언트 연결 명령용이다.
  # 앱 사용자와 같은 이유로 `&*`를 유지해 plan에 영구 diff가 생기지 않게 한다.
  # ElastiCache가 자동으로 추가하는 `-@all`을 명시해 반복적인 사용자 수정을 막는다.
  human_access_string = join(" ", [
    "on",
    "~*",
    "&*",
    "-@all",
    "+@read",
    "+@write",
    "+@connection",
    "-@dangerous",
  ])
}

resource "aws_elasticache_user" "human" {
  for_each = local.human_users

  user_id       = each.value
  user_name     = each.value
  access_string = local.human_access_string
  engine        = "valkey"

  authentication_mode {
    type = "iam"
  }

  tags = {
    Name = each.value
  }
}

data "aws_iam_policy_document" "human_connect" {
  for_each = local.human_users

  statement {
    sid     = "ConnectToValkeyAsOwnUser"
    effect  = "Allow"
    actions = ["elasticache:Connect"]
    resources = [
      aws_elasticache_serverless_cache.valkey.arn,
      aws_elasticache_user.human[each.key].arn,
    ]
  }
}

resource "aws_iam_policy" "human_connect" {
  for_each = local.human_users

  name        = "${each.value}-connect"
  description = "Allow IAM user ${each.key} to connect to the V2 ${local.environment_label} Valkey as its own user"
  policy      = data.aws_iam_policy_document.human_connect[each.key].json

  tags = {
    Name = "${each.value}-connect"
  }
}

resource "aws_iam_user_policy_attachment" "human_connect" {
  for_each = local.human_users

  user       = each.key
  policy_arn = aws_iam_policy.human_connect[each.key].arn
}
