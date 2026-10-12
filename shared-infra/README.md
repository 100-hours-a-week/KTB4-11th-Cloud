# Shared infrastructure

애플리케이션 서버와 AI 서버가 함께 사용하는 VPC, public subnet, internet gateway, route table을 관리합니다.

S3의 `shared-infra/terraform.tfstate`에는 기존 네트워크 6개가 이미 import되어 있습니다. `app-server`와 `ai-server/infra`는 이 state의 VPC와 subnet output을 참조합니다.

## Private 네트워크 (ECS)

ECS 컨테이너 인스턴스용 Private Subnet과 아웃바운드 경로를 관리합니다.

| 리소스 | 구성 |
|---|---|
| Private Subnet | `10.0.11.0/24` (2a), `10.0.12.0/24` (2c) |
| NAT Gateway | 2a Public Subnet에 1개, EIP 고정 |
| Private Route Table | `0.0.0.0/0` → NAT Gateway |
| S3 Gateway Endpoint | Private Route Table에 연결 (Private ECR 이미지 레이어 전송 비용 절감) |

- awsvpc 모드의 EC2 Task는 Public IP를 받을 수 없어 NAT Gateway가 필수입니다.
- NAT Gateway는 비용을 고려해 1개만 둡니다. 2a AZ 장애 시 2c의 Private Subnet도 외부 통신이 끊기는 **단일 장애 지점**이므로, 운영 요구가 커지면 AZ별 NAT Gateway로 전환합니다.
- 외부 API에 IP 허용 목록 등록이 필요하면 `nat_gateway_public_ip` output을 사용합니다.
