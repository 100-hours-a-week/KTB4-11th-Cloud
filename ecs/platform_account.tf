# ENI Trunking을 켜야 awsvpc 모드에서 인스턴스당 실행 가능한 Task 수가 늘어난다.
# 이 설정은 활성화 이후 시작된 컨테이너 인스턴스에만 적용되므로, ASG보다 먼저 apply한다.
# 계정·리전 단위 기본값이므로 같은 계정의 다른 ECS 사용에도 영향을 준다.
resource "aws_ecs_account_setting_default" "awsvpc_trunking" {
  name  = "awsvpcTrunking"
  value = "enabled"
}
