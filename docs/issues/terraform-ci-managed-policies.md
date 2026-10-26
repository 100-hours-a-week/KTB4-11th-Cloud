# refactor: Terraform CI 쓰기 권한을 기능별 관리형 정책으로 분리

## 구현할 기능

CI apply 역할의 인라인 정책 총량 제한을 해소하고, CloudWatch 관측 기능을 확장할 수 있도록 리소스 쓰기 권한을 고객 관리형 정책으로 분리한다.

## 작업 상세 내용

- [ ] compute·application·observability·identity 관리형 정책 4개로 분리
- [ ] 각 정책의 6,144자 한도를 plan에서 검사
- [ ] 기존 Action·Resource·Condition의 의미상 동등성 검증
- [ ] 새 정책 연결 단계에서 기존 인라인 권한 유지
- [ ] 연결 검증 후 기존 resource-write 인라인 정책만 제거
- [ ] state-write·read·state-access 정책 유지
- [ ] 로컬 bootstrap 권한과 2단계 적용·검증 절차 문서화

## 적용 조건

pattie_for_terraform의 CreatePolicy·AttachRolePolicy·DeleteRolePolicy 권한이 현재 부족하다. 관리자가 필요한 대상에 한정한 권한을 먼저 허용해야 하며, CI 자체로 자기 권한을 수정하지 않는다. 이슈의 AWS 적용 완료는 2단계 전환과 CI 확인까지 수행한 뒤 표시한다.
