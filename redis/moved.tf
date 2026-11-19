# 사용자·Policy를 서비스별 for_each로 바꾸면서 기존 dev 리소스를 교체 없이 옮깁니다.
moved {
  from = aws_elasticache_user.backend
  to   = aws_elasticache_user.app["backend"]
}

moved {
  from = aws_iam_policy.backend_connect
  to   = aws_iam_policy.app_connect["backend"]
}

# The resource became count-based so dev can be retired while prod remains managed.
moved {
  from = aws_elasticache_serverless_cache.valkey
  to   = aws_elasticache_serverless_cache.valkey[0]
}
