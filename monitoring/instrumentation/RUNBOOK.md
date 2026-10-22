# 운영 앱 Tempo 연결

`backend`, `backend-collector`, `market-http`의 **실행 중인 이미지 digest**에서
계측 이미지를 파생한다. 기존 앱 소스·DB 설정·Task CPU/메모리·시세 수집 설정은 유지한다.
Java 계측은 이미지 entrypoint에 연결하고 Task의 기존 JVM 옵션은 유지한다.
Java agent 2.32.0은 SHA-256을 검증하고, Python SDK 1.45.0 / instrumentation 0.66b0은
해시 잠금 파일로 설치한다. Python 빌드는 기존 앱 의존성을 바꿔야 하면 실패한다.

## 1. 준비 — AWS 읽기와 로컬 파일 생성만 수행

cloud 저장소 루트에서 실행한다. 운영 변경과 `terraform apply`는 운영자가 직접 실행한다.

```bash
AWS_PROFILE=stockspoon AWS_REGION=ap-northeast-2 \
  terraform -chdir=ecs plan -out=tempo-resume.tfplan
python3 monitoring/prepare-tracing.py \
  --plan ecs/tempo-resume.tfplan --directory /tmp/stockspoon-tempo
cat /tmp/stockspoon-tempo/manifest.json
```

현재 서비스가 안정 상태이고, 같은 서비스의 모든 Task가 동일한 이미지를 실행할 때만
준비된다. 원본 Task Definition도 보관한다. 디렉터리가 이미 있으면 새 경로를 사용한다.

## 2. 이미지 빌드·업로드 — 운영자가 실행

Docker를 실행하고 아래 스크립트를 검토한 뒤 실행한다. 실행 중인 앱 버전에서
`linux/amd64` 이미지를 만들고 기존 public ECR 저장소에 별도 `tempo-*` 태그로 업로드한다.
애플리케이션 코드는 다시 빌드하지 않는다.

```bash
bash /tmp/stockspoon-tempo/build-images.sh
```

## 3. 수집기 — Terraform으로 교체

```bash
AWS_PROFILE=stockspoon AWS_REGION=ap-northeast-2 \
  terraform -chdir=ecs plan \
    -var-file=/tmp/stockspoon-tempo/collector-image.tfvars.json \
    -out=tempo-instrumented.tfplan
```

수집기 Task Definition·서비스와 telemetry 출력 외의 변경이 없는지 확인한 뒤 적용한다.
수집기는 단일 소유자 제약 때문에 **기존 Task 종료 → 새 Task 시작** 순서이며
교체 중 REST 수집 공백이 발생한다. `skip_destroy=true`로 원래 Task Definition은 남는다.

```bash
AWS_PROFILE=stockspoon AWS_REGION=ap-northeast-2 \
  terraform -chdir=ecs apply tempo-instrumented.tfplan
```

`collector-image.tfvars.json`의 값을 다음 운영 plan에도 동일하게 제공한다.
일회성으로 생략하면 원래 수집기 이미지로 되돌리는 plan이 생성된다.

## 4. market-http와 backend — CD 소유 Task Definition 갱신

```bash
bash /tmp/stockspoon-tempo/deploy-apps.sh
```

Terraform의 `ignore_changes`를 유지한다. 스크립트가 새 revision을 등록하고
market-http → backend 순서로 서비스 갱신과 안정화를 기다린다. 등록 전 서비스 revision이
준비 시점과 달라졌으면 중단한다. 이미지·OTLP 환경변수 외의
기존 Task 설정은 보존하며, 실패 시 다음 서비스 배포를 진행하지 않는다.
market-http는 Task 교체 시 SSE가 재연결될 수 있다.

## 5. 확인과 복구

정상 애플리케이션 요청을 발생시킨 뒤 Grafana Explore의 Tempo에서 각각 조회한다.
health check만 발생시키지 말고 실제 API 요청을 사용한다.

```text
{ resource.service.name = "market-http" && resource.deployment.environment.name = "prod" }
{ resource.service.name = "backend" && resource.deployment.environment.name = "prod" }
{ resource.service.name = "backend-collector" && resource.deployment.environment.name = "prod" }
```

기본 새 요청 샘플링 비율은 10%다. 통제된 시험에서 전체 추적이 필요하면
`telemetry_trace_sample_ratio=1`로 plan부터 다시 준비하며, 시험 후 원복한다.
SSE 서버 span은 연결이 끝나야 보일 수 있다. Redis·JDBC·HTTP 등 지원 라이브러리의
호출을 추적하며, 모든 사용자 코드 내부 구간을 자동으로 나눠주는 것은 아니다.
기존 로그 포맷의 trace ID 상관관계와 개발 앱 계측은 별도 검증 대상이다.
향후 일반 CD에서도 추적을 유지하려면 해당 파이프라인의 이미지 빌드에 같은
계측 단계를 연결해야 한다. 일반 앱 이미지로 교체하면 앱은 동작하지만 추적은 중단된다.

두 CD 소유 앱의 원래 revision으로 복구하려면 다음 스크립트를 검토 후 실행한다.

```bash
bash /tmp/stockspoon-tempo/rollback-apps.sh
```

수집기는 `backend_collector_instrumented_image=null`로 새 plan을 검토·적용해 원복한다.
DB 마이그레이션 PLG/PMM, ProxySQL, 다른 시세 서비스는 이 작업 대상이 아니다.

공식 자료: [Java agent](https://opentelemetry.io/docs/zero-code/java/agent/getting-started/),
[Python zero-code](https://opentelemetry.io/docs/zero-code/python/).
