# ECR

Private ECR 저장소를 관리하는 Terraform root입니다.
이미지 저장소는 ECS 클러스터와 수명이 다르고 CI·운영 ECS가 함께 사용하므로 `ecs` root와 분리했습니다.

## 저장소

| 이름 | 용도 |
|---|---|
| `stockspoon-v2-prod-backend` | V2 Backend 운영 이미지 (운영 ECS) |

- 이름은 `stockspoon-{버전}-{환경}-{서비스}` 형식이며, IAM 접두사(`stockspoon-v2-dev-*`, `stockspoon-v2-prod-*`)와 같은 규칙입니다.
- 환경별로 저장소를 나눠 개발 CI가 운영 저장소에 push하지 못하도록 권한을 분리합니다. V2 개발 이미지는 기존 Public ECR `stockspoon-v2-backend`를 사용합니다.
- 저장소를 추가하면 `app-server/terraform_github_actions.tf`의 Private ECR 이름 목록도 함께 갱신해야 CI apply가 가능합니다.

## 이미지 정책

- 태그 불변(`IMMUTABLE`): 배포 시 git SHA 등 매번 다른 태그를 사용합니다.
- push 시 이미지 스캔
- untagged 이미지 7일 후 삭제, 최근 30개만 보관

## 참조

다른 root는 `repository_urls` output을 remote state로 참조합니다. 이 root는 다른 root를 참조하지 않습니다.
