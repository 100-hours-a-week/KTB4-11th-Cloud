# ---------------------------------------------------------------------------
# ECS 컨테이너 인스턴스 Role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_instance_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_instance" {
  name               = "${var.name_prefix}-ecs-instance-role"
  description        = "Role for ECS container instances to register with the cluster"
  assume_role_policy = data.aws_iam_policy_document.ecs_instance_assume_role.json
}

# ECS Agent의 클러스터 등록, 이미지 Pull, 로그 전송
resource "aws_iam_role_policy_attachment" "ecs_instance_ecs" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# SSH 대신 Session Manager로 접속
resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.name_prefix}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance.name
}

# ---------------------------------------------------------------------------
# Task Execution Role
# ECS Agent가 Task를 시작할 때 사용한다. (이미지 Pull, 로그 그룹 쓰기, Secret 주입)
# 애플리케이션 코드가 쓰는 권한은 서비스별 Task Role에 둔다.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # 다른 계정의 ECS가 이 Role을 대신 사용하는 것(confused deputy)을 막는다.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.name_prefix}-ecs-task-execution-role"
  description        = "Role used by the ECS agent to pull images, write logs, and inject secrets"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

# ECR Pull, CloudWatch Logs 쓰기
resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task Definition의 secrets로 주입할 SSM 파라미터 조회
# 기본 aws/ssm KMS 키로 암호화한 SecureString은 kms:Decrypt 권한 없이 읽을 수 있다.
# 고객 관리형 KMS 키를 쓰게 되면 해당 키의 kms:Decrypt를 추가한다.
data "aws_iam_policy_document" "ecs_task_execution_secrets" {
  statement {
    sid       = "ReadProductionParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameters"]
    resources = [local.ssm_parameter_arn_glob]
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  name   = "${var.name_prefix}-ecs-task-execution-secrets"
  role   = aws_iam_role.ecs_task_execution.id
  policy = data.aws_iam_policy_document.ecs_task_execution_secrets.json
}
