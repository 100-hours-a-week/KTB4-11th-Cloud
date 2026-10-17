# V2 프론트엔드 운영 배포

## 현재와 목표

현재 FE의 `dev` CI는 v2 frontend 이미지 빌드 후 `stockspoon-v2-frontend` Public ECR에 올리고, 개발 서버에 배포한다. 이 저장소의 `ecs` root에는 운영 백엔드·market 서비스만 있다. 운영 FE 배포는 아직 연결되어 있지 않다.

FE는 Next.js standalone 서버, `proxy.ts`, 런타임 동적 경로와 기본 이미지 최적화를 사용한다. 따라서 FE 소스 변경 없이 전체 사이트를 S3에서 실행할 수는 없다. 이 구성은 같은 standalone 이미지를 기존 ECS 클러스터에서 실행하고, 빌드와 일치하는 `/_next/static/*`만 비공개 S3에서 제공한다. API는 기존 ALB 경로 규칙을 통과한다.

## 단계별 전환

Terraform 기본값은 CloudFront, S3 정적 파일 전달, FE ECS 서비스, DNS 변경 모두 꺼져 있다. `stock-spoon.com`은 v1 ALB를 계속 가리킨다. 각 단계를 별도 plan으로 확인한 뒤 다음 순서를 따른다.

1. `ecr` root가 태그 불변 운영 저장소 `stockspoon-v2-prod-frontend`를 만든다.
2. `app-server`에서 `frontend_edge_enabled=true`로 전용 S3, CloudFront, us-east-1 ACM 인증서, 퍼블리셔 역할을 만든다. DNS는 ALB에 그대로 둔다.
3. FE `cd-v2-prod` 워크플로가 소스 SHA로 이미지를 빌드하고 ECR에 push한다. 같은 이미지 digest의 `.next/static`을 S3의 `/_next/static/`에 sync하고 CloudFront에서 그 prefix만 무효화한다. 서버 페이지는 캐시하지 않는다.
4. `ecs`에서 `frontend_enabled=true`, `frontend_image=<ECR URI>@sha256:<digest>`로 서비스 2개를 띄운다. 이미지 digest와 S3 정적 파일은 반드시 동일한 빌드에서 와야 한다.
5. 두 task의 `/health`가 정상이고 CloudFront 도메인으로 페이지·로그인·API를 확인한 뒤 `app-server`의 `frontend_v2_origin_ready=true`를 설정한다. 이것은 CloudFront가 ALB에 `X-Stockspoon-Frontend: v2` 헤더를 전달하게 한다. ALB의 priority 300 규칙만 FE ECS로 보내며, API priority 100과 market priority 200은 기존 대상을 유지한다.
6. 최종 확인 후 `app-server`에서 `app_dns_target="cloudfront"`로 전환한다. 이 값은 `frontend_edge_enabled`, `frontend_assets_ready`, `frontend_v2_origin_ready`가 모두 true일 때만 허용한다. Route 53 A/AAAA alias가 CloudFront를 가리킨다.

롤백은 먼저 `app_dns_target="alb"`로 돌린 다음 `frontend_v2_origin_ready=false`로 바꾼다. v1 DNS는 CloudFront cutover 전까지 변경되지 않는다. 현재 설정은 자동으로 트래픽을 옮기지 않는다.

## 브랜치와 GitHub 배포 계약

`app-server/frontend_variables.tf`의 `frontend_deployment_branch`가 허용 브랜치 한 곳을 정한다. 지금 값은 `dev`다. FE 운영 배포를 `main`에서 시작할 때 이 값을 `main`으로 바꿔 plan/apply한다. 출력한 `frontend_deployment_contract.oidc_subject`를 운영 배포 Role이 사용하므로, FE workflow의 `role-to-assume`도 `frontend_edge.deploy_role_arn`으로 바꾼다. OIDC 조건을 일치시키려면 해당 job에서 GitHub `environment:`를 사용하지 않는다. Environment subject로 바꾸려면 Trust policy도 같은 subject로 맞춰야 한다.

워크플로는 FE 저장소에 추가해야 한다. 현재 FE 저장소 파일은 수정하지 않았다. 워크플로는 아래를 수행한다.

- OIDC로 Cloud role을 assume하고 `frontend_edge.deploy_role_arn`을 사용한다.
- SHA 태그로 빌드·push하고, push한 digest를 ECS에 배포한다.
- 그 이미지의 `.next/static`만 S3 `frontend_edge.assets_bucket/_next/static/`에 올린다.
- 업로드 후 CloudFront `frontend_edge.distribution_id`의 `/_next/static/*`만 무효화하고 ECS rollout이 안정될 때까지 확인한다.
- 배포 job에 사용자 선택 브랜치 제한과 protected main branch 검토 규칙을 둔다.

`frontend_assets_ready=true`는 해당 release의 assets가 먼저 올라간 뒤 사용한다. ECS 새 task가 정상인 다음 `frontend_v2_origin_ready=true`로 바꾸고, CloudFront 도메인을 ALB로 연결해 `stock-spoon.com` Host와 TLS를 유지한 상태로 검증할 수 있다.

## Terraform apply Role 권한 변경

Terraform plan Role은 state와 관리 리소스를 읽는다. apply Role은 현재 연결된 관리형 정책 범위에서 인프라를 바꾸지만, 자기 IAM Role, Trust policy, 연결된 권한 정책을 변경할 권한은 없다. 이 제한은 GitHub main PR plan이 노출되거나 workflow가 변조되어도 Terraform CI가 스스로 관리자 권한을 붙이지 못하게 한다.

이 변경은 `app-server/terraform_github_actions_policies.tf`의 read 권한과 `modules/terraform-ci-policies/edge.tf`의 별도 `edge` write policy를 IaC에 추가한다. plan에는 read policy 갱신과 edge policy 연결이 나타난다. 현재 apply Role은 이 자기 권한 변경을 승인할 수 없으므로, 첫 연결은 조직의 AWS 관리자 승인된 IAM 프로비저닝 경로로 처리해야 한다. 이 세션에서는 해당 변경이나 apply를 실행하지 않았다.

승인된 IAM 관리자 또는 별도 IAM 관리 파이프라인이 `stockspoon-v1-github-actions-terraform-apply` Role과 정확한 Terraform policy ARN만 대상으로 필요한 정책 버전 갱신·신규 managed policy 연결을 허용한다. 그다음 보호된 Cloud `main`에 병합해 Terraform workflow가 이 저장소의 정책 문서와 Role attachment를 관리하도록 전환하고, bootstrap 권한을 회수한다. `iam:*`, 전체 계정 관리자 권한, GitHub Secret에 장기 AWS key를 넣는 방식은 필요하지 않다. Role의 OIDC Trust는 Cloud `main` 제한을 유지한다.

FE deploy Role은 이 Terraform apply Role과 별개다. ECR production 저장소, `/_next/static/*`의 S3 prefix, CloudFront distribution, 해당 FE ECS service에 필요한 배포 작업만 허용한다. FE repository ID와 단일 branch OIDC subject로 assume할 수 있게 한다.

## 비용 가정

2026-10-17에 확인한 AWS 종량제 가격 기준이다. 환율·세금 제외, 월 사용량은 계정에서 함께 쓰는 다른 애플리케이션과 공유된다.

| 항목 | 예상 비용 |
| --- | --- |
| CloudFront | 계정 내 월 1 TB 인터넷 송신과 1천만 HTTP(S) 요청까지 무료 사용량 적용. 초과분은 한국 edge 기준 다음 9 TB $0.120/GB, HTTPS $0.012/1만 요청. `PriceClass_All`은 Seoul 포함. |
| S3 Standard | 최초 50 TB 구간 $0.025/GB-month. 1 GB 평균 사용 시 약 $0.025/월, 10 GB면 $0.25/월. GET은 1만 회당 $0.0035, PUT은 1천 회당 $0.0045. 오래된 정적 asset은 180일 후 삭제하고, 과거 object version은 30일 뒤 지운다. CloudFront origin에서 인터넷으로 직접 전송하지 않는다. |
| 비공개 ECR | 저장은 약 $0.10/GB-month. 새 계정에서만 첫해 private ECR 500 MB free tier가 적용된다. lifecycle은 최근 30개 이미지를 남긴다. 서울 ECS에서 같은 리전 저장소로 이미지를 pull하면 전송료는 무료다. |
| ALB·Route 53·ACM | 기존 ALB와 hosted zone을 재사용하고 ACM public certificate는 무료라 새 ALB 시간당 비용은 추가되지 않는다. FE 요청에 따른 ALB LCU 사용량은 늘 수 있다. |
| ECS/EC2 | FE task 하나는 0.25 vCPU/512 MiB, 기본 2개다. 현재 ECS ASG는 `c6i.xlarge` 2대 이상, 최대 4대다. 여유가 있으면 EC2 증설은 없고, capacity provider가 EC2를 늘리면 그 비용이 가장 큰 변동 항목이다. 실제 사용량과 ECS CPU/Memory를 보고 조정한다. |

기본 시작값은 월 CloudFront 전송·요청 무료 사용량 안에 머무르면 CloudFront와 S3의 합계가 소액이다. ECR 저장과 ECS 용량이 별도 변수다. 실제 월 비용은 FE S3 크기와 이미지 보관량, 계정 전체 CloudFront 사용량, ECS 여유 용량을 확인한 뒤 확정한다.

## 현재 plan 결과

기본값으로 `app-server` plan은 기존 인프라에서 삭제·교체를 제안하지 않는다. Terraform CI read 권한과 ECR 저장소 관리 policy 수정, edge write policy 생성을 계획한다. Edge를 켠 plan은 CloudFront·S3·ACM 리소스 15개 추가, 2개 policy 수정, 0개 삭제를 제안한다. `ecr` plan은 전용 production repository와 lifecycle policy 2개 추가, 0개 삭제다. ECS 기본값은 비활성 상태라 `ecs` plan은 변경 없음이다. Terraform apply는 실행하지 않았다.

AWS 가격 근거: [CloudFront 종량제](https://aws.amazon.com/cloudfront/pricing/pay-as-you-go/), [S3 가격](https://aws.amazon.com/s3/pricing/), [ECR 가격](https://aws.amazon.com/ecr/pricing/).
