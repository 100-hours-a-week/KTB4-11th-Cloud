# Backend 서비스 전용 리소스
# Target Group, Task Definition, ECS Service는 다음 이슈에서 이 파일에 추가한다.

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.name_prefix}/backend"
  retention_in_days = var.container_log_retention_days
}

# ---------------------------------------------------------------------------
# Task Role
# 애플리케이션 코드가 AWS API를 호출할 때 사용한다.
# 지금은 권한 없이 만들고, 운영 SQS 등 필요한 권한은 해당 리소스를 만들 때 추가한다.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "backend_task" {
  name               = "${var.name_prefix}-backend-task-role"
  description        = "Role assumed by the backend application containers"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}
