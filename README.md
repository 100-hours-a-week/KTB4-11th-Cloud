# KTB4-11th Cloud

StockSpoon의 AWS 인프라와 애플리케이션 배포 구성을 관리하는 저장소입니다.

## 구성

- 현재 dev 브랜치 기준입니다.

| 경로 | 역할 |
| --- | --- |
| `shared-infra/` | 앱 서버와 AI 서버가 공유하는 네트워크 |
| `app-server/` | 프론트엔드·백엔드가 실행되는 V1 앱 서버 |
| `ai-server/infra/` | AI 서버 인프라 |
| `ai-server/dashboard/` | AI 서버 모니터링 |
| `docker-compose.yaml`, `nginx/`, `scripts/` | 앱 서버 실행 및 배포 구성 |

## 현재 브랜치

현재 Terraform과 배포 구성은 V1 환경을 기준으로 합니다.

| 브랜치 | 역할 |
| --- | --- |
| `main` | 프론트엔드와 백엔드의 V1 배포가 참조하는 Cloud 저장소 브랜치 |
| `dev` | 실제 V1 AWS 리소스에 Terraform을 적용하는 배포 기준 브랜치 |
| `feat/*`, `fix/*`, `refactor/*` | 작업 브랜치. 검증 후 `dev`에 병합 |


## V2 전환 계획

V2 개발을 시작하면 다음과 같이 브랜치를 운영합니다.

| 브랜치 | 환경 | 역할 |
| --- | --- | --- |
| `release-v1` | V1 운영 | 현재 `main`을 전환하여 V1 서비스 유지보수 |
| `dev` | V2 개발 | V2 변경 통합 및 실제 개발 서버 배포 |
| `release-v2` | V2 운영 | 검증이 끝난 V2 운영 배포 |

V2 전환 시 프론트엔드와 백엔드의 V1 배포는 `release-v1`, V2 배포는 환경에 따라 `dev` 또는 `release-v2`를 참조합니다.

## Terraform state 원칙

개발 서버와 운영 서버는 같은 Terraform state를 사용하지 않습니다.

- 환경별로 state와 함께 EC2, 데이터베이스, DNS, IAM Role, GitHub Actions Secret도 분리합니다.

| 환경 | State 예시 |
| --- | --- |
| V1 운영 | `prod-v1/.../terraform.tfstate` |
| V2 개발 | `dev-v2/.../terraform.tfstate` |
| V2 운영 | `prod-v2/.../terraform.tfstate` |
