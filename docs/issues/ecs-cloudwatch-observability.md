# feat: ECS 부하·마이그레이션·장애 실험용 CloudWatch 관측 구성

## 구현할 기능

V2 ECS의 자동 확장, V1→V2 Backend 무중단 마이그레이션, 향후 장애 주입 실험을 같은 시간축에서 분석할 수 있도록 로그·메트릭·대시보드·장애 감지 알람을 구성한다.

## 작업 상세 내용

- [ ] V2 ECS 전용 CloudWatch 통합 대시보드 추가
- [ ] Backend·SSE CPU·메모리·Desired/Running/Pending 및 SSE 연결 수 표시
- [ ] ASG 그룹 지표 1분 수집과 Capacity Provider 용량 표시
- [ ] V1 Blue·V2 Backend·SSE Target Group별 요청·오류·지연·건강 상태 비교
- [ ] ECS Task·인스턴스·서비스·배포와 ASG 이벤트를 EventBridge로 보존
- [ ] 기존 Container Insights 성능 로그 그룹 import 및 보존 30일 적용
- [ ] 실험 마커와 k6 원시 결과의 CloudWatch EMF 업로드 도구 추가
- [ ] FIS 중단 조건으로 참조 가능한 서비스 장애 알람과 output 추가
- [ ] 수집 도구 테스트 및 실험 운영 안내 작성

## 완료 기준

- Terraform validate·fmt·plan 통과, 서비스 재배포·리소스 삭제 없음
- CI 관측 권한 적용 후 로그·대시보드·알람·ASG 지표 반영
- 이벤트 규칙 패턴과 새 로그 유입 확인
- 실험 마커·원시 지연 표본·실패 수 업로드 확인
- FIS 실행·실제 부하 생성·SSE 부하 스크립트는 별도 실험 작업으로 진행

## 의존성

Terraform CI 관리형 정책 분리 및 로컬 적용 권한 준비를 먼저 진행한다. 알림 수신자·FIS 실험은 별도 설정이며, 클라이언트 지표는 결과 업로드 전까지 비어 있다.
