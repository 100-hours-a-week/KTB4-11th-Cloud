# Terraform CI/CD

## Root 의존성

`.github/scripts/terraform_roots.py`의 `ROOT_DEPENDENCIES`에 소비 root가 필요한 선행 root를 정의한다.
`ROOT_ORDER`와 `DEPENDENTS`는 이 정의에서 자동 계산하며 직접 수정하지 않는다.
새 root·remote state 참조를 추가할 때는 이 정의와 계약 테스트를 함께 갱신한다.
조건부로 읽는 state도 의존성에 포함한다.

- 변경된 root와 영향을 받는 downstream root만 선택한다.
- 이미 배포된 상위 root는 기존 S3 state를 사용하며 매번 재적용하지 않는다.
- `messaging`·`redis` 공통 코드 변경은 dev와 prod를 함께 선택한다.
- `environments/dev/`·`environments/prod/` 변경은 해당 환경에서 시작한다.
- 배포 helper·Terraform workflow 변경은 전체 root를 검사한다.
- 순환 의존성, 알 수 없는 root·환경은 AWS 명령 전에 실패한다.

## 실행 흐름

PR에서는 helper 테스트와 Terraform 검증 후 읽기 전용 역할로 Plan을 실행한다.
main에서는 helper 테스트 후 의존성 순서대로 각 root의 Plan과 Apply를 실행한다.
상위 root의 적용 결과를 반영하도록 각 root의 Plan은 Apply 직전에 생성한다.
별도의 중복 Main Plan job은 실행하지 않는다.

변경 범위는 마지막으로 성공한 main Apply workflow의 커밋부터 계산한다.
대기 중 취소되거나 실패한 push의 변경도 다음 실행에 포함한다.
처음 실행하거나 Git 이력이 바뀌어 기준 커밋을 사용할 수 없으면 전체를 검사한다.
최신 성공 배포보다 오래된 커밋을 재실행해도 인프라를 되돌리지 않는다.
재활성화 직후에는 중단 기간에 누적된 변경을 모두 선택할 수 있다.

monitoring은 배포된 서버·개발 연결·Grafana 주소를 유지하도록
`monitoring/development.tfvars.example`을 CI에서도 사용한다.
messaging과 redis는 환경별 backend와 변수 파일을 사용한다.
비밀 값은 변수 예제 파일에 넣지 않는다.

Apply 로그는 실시간으로 출력하고 root별 소요 시간을 기록한다.
provider cache는 각 runner 안에서 재사용하며, 병렬 runner 사이에 공유하지 않는다.
진행 중인 Apply를 취소하지 않도록 main workflow의 `cancel-in-progress: false`를 유지한다.

## 검증

```bash
python3 -m unittest discover -s scripts/tests -p 'test_terraform_*.py' -v
python3 -m py_compile .github/scripts/terraform_*.py
terraform -chdir=monitoring fmt -check -recursive
```

계약 테스트는 backend와 remote state 참조, 적용 순서, 환경 선택,
실패·취소된 push 이후 변경 범위, 실패 시 후속 Apply 중단을 검증한다.
