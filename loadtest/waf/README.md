# CloudFront WAF rate-limit experiment

이 실험의 목적은 현재 WAF 기준이 정상 API 사용량을 허용하면서, 한 IP에서 급증한 `/api/` 요청을 감지·제한하는지 확인하는 것입니다.

## 현재 코드 기준 가설

`app-server/waf.tf`와 `app-server/modules/api-waf/main.tf`의 기본값은 다음과 같습니다.

- CloudFront에 WAF 연결: `api_waf_enabled = true`
- 관찰 모드: `api_waf_mode = "count"` (기준 초과를 관찰하고 요청은 통과)
- 집계 기준: viewer IP
- 적용 범위: `/api/` 경로
- 요청 기준: IP당 300초 동안 500회

500회는 실측값이 아닙니다. 모듈 주석의 가정인 `6.8회/방문 × 2회/5분 × 10명 × 3배 여유 ≈ 408회`를 500으로 올림한 값입니다.

### H1: 정상 사용자 패턴은 WAF 기준보다 낮다

- 한 k6 발생기에서 10개 VU를 실행합니다. 이 VU들은 WAF 기준상 같은 viewer IP로 집계됩니다.
- 한 번 방문할 때 읽기 API 7회를 호출하고, 각 VU가 5분 동안 2회 방문합니다.
- 예상량은 `10 VU × 2회 × 7요청 = 140요청/5분`이며 500회보다 낮습니다. 이 VU는 사용자 10명의 요청량을 대신하는 모델입니다.
- 기대 결과: 정상 API 요청 성공, 제한 기준 초과 없음, p95 응답시간이 임시 기준인 1초 이내.

현재 스크립트는 모든 VU가 같은 테스트 토큰과 계좌 ID를 사용합니다. 이 구성은 WAF의 IP별 요청량 가설을 검증하지만, 서로 다른 사용자 데이터 분포까지 재현하지는 않습니다.

경로는 현재 FE 구현에서 확인한 사용자 조회, 홈 화면의 계좌·보유·주문 조회, 계좌 목록, 관심종목 조회를 사용합니다. 일곱 번째 호출은 6.8회를 7회로 반올림한 시험 모델입니다. 실제 사용자 행동의 측정값은 아니므로 운영 트래픽이나 FE 요청 기록으로 보정해야 합니다.

CloudFront 설정은 `/api/*`에 캐시 비활성 정책을 사용하므로 이 요청들은 캐시 적중 대신 WAF와 애플리케이션 경로를 시험합니다.

### H2: 한 IP에서 증가한 요청은 기준을 넘는다

- 별도 k6 발생기에서 초당 3회, 6분 동안 같은 `/api/` 경로를 호출합니다.
- 기본 기준(500회/300초)에서 완전한 5분 구간의 요청량은 900회입니다.
- `Count`에서는 WAF 로그/지표에서 기준 초과를 관찰합니다. `Block`에서는 제한된 요청이 429를 반환해야 합니다.
- Flood 실행 결과에는 2xx, 429, 그 밖의 응답 수와 요청 지연시간이 따로 기록됩니다. Count에서 2xx가 대부분인지, Block에서 429가 늘어나는지 비교하고, 그 밖의 응답이나 지연 증가도 확인합니다.
- 429만으로 WAF 차단을 확정하지 말고 WAF 로그에서 해당 요청의 종료 규칙이 `api-per-source-ip`인지 확인합니다. 애플리케이션도 429를 반환할 수 있습니다.

### H3: 요청이 많은 IP와 정상 IP를 분리한다

- H1과 H2를 서로 다른 공인 egress IP에서 동시에 실행합니다.
- 기대 결과: 부하 IP는 WAF에 감지·제한되고, 정상 IP의 요청은 계속 성공합니다.
- `X-Forwarded-For`를 꾸며내지 않습니다. 한 k6 발생기의 VU는 모두 같은 출발지 IP를 공유합니다.

## 실행 순서

1. 실제 배포 설정에서 Web ACL이 CloudFront에 붙어 있는지 확인합니다. Terraform 기본값과 실제 배포값은 다를 수 있습니다.
2. `/api/` 요청이 CloudFront 경로를 통과하는 소량 `smoke` 실행으로 대상 URL, 테스트 토큰, 계좌 ID, 일곱 경로를 확인합니다.
3. H1 정상 패턴을 `Count` 모드에서 실행하고 정상 요청 오류율·p95·WAF 지표를 기록합니다.
4. H2를 별도 IP에서 실행해 WAF 기준 초과 기록을 확인합니다. `Count`는 요청을 막지 않으므로 서버 지표도 함께 기록합니다.
5. 정상 요청이 기준 아래임을 확인한 뒤에만 `api_waf_mode = "block"`으로 바꾸고 H2/H3를 반복합니다.

`loadtest/waf/rate-limit.js`의 기본값은 `MODE=smoke`, `NORMAL_USERS=10`, `FLOOD_RPS=3`입니다. `NORMAL_ACCOUNT_ID`에는 폐기 가능한 테스트 계좌 ID, `ACCESS_TOKEN`에는 테스트 계정 토큰을 전달합니다. 실제 API 경로가 다르면 `NORMAL_PATHS`로 읽기 전용 경로 배열을 지정합니다.

예시 환경변수 설정:

```sh
export BASE_URL='https://<CloudFront 도메인>'
export ACCESS_TOKEN='<테스트 계정 토큰>'
export NORMAL_ACCOUNT_ID='<테스트 계좌 ID>'
```

정상 발생기에서는 `MODE=smoke`로 경로와 인증을 확인한 뒤 `MODE=normal NORMAL_USERS=10`으로 H1을 실행합니다. 다른 egress IP를 쓰는 부하 발생기에서는 `MODE=flood FLOOD_RPS=3`으로 H2를 실행합니다. 이 명령은 문서에만 기록했으며 실행하지 않았습니다.

`smoke`와 `normal`은 정상 시나리오만 실행하고 `flood`는 별도 실행합니다. H3를 확인하려면 서로 다른 egress IP를 가진 두 테스트 발생기에서 동시에 실행해야 합니다. 하나의 호스트에서 터미널만 두 개 띄우면 출발지 IP가 같으므로 H3가 되지 않습니다.

## Flood 모니터링 대시보드

`monitoring/config/grafana/dashboards/prod/http-flood.json`은 다음 신호를 한 화면에서 비교합니다.

- WAF rate rule의 `CountedRequests`와 `BlockedRequests`
- CloudFront 전체 요청·오류율, V2 Backend Target Group의 요청·오류·응답시간
- Spring API route별 요청량·p95·앱 429/5xx
- Tomcat 스레드, Hikari 연결 풀, ECS Task CPU·메모리
- Loki의 Spring 요청 감사 로그에서 앱 429/5xx와 1초 이상 지연 요청

`CountedRequests`는 전체 API 요청 수가 아니라 rate rule에 매칭된 요청 수입니다. WAF 지표는 약 1분 단위로 보고되므로 k6 실행 시각을 기록하고 같은 시간 범위로 비교합니다.

요청별 출발지 IP와 URI가 필요하면 CloudWatch Logs의 `aws-waf-logs-stockspoon-api-rate-limit` 로그 그룹을 `us-east-1`에서 확인합니다. 현재 Grafana IAM 권한은 ECS 성능 로그 그룹만 Logs Insights 조회를 허용하므로, WAF 상세 로그는 AWS 콘솔에서 조회합니다. Grafana 대시보드는 저장소에서 파일로 관리되며, 이 파일을 실제 모니터링 서버에 배포해야 화면에 나타납니다.

### k6 요청 단위 보조 지표

- `response_body_bytes`: k6가 응답 본문으로 받은 바이트 크기입니다. `scenario_type`과 정규화한 `uri`로 구분하며 응답 원문은 저장하지 않습니다. 네트워크 wire bytes 전체를 뜻하지는 않습니다.
- `response_content_length_bytes`: 응답에 `Content-Length` 헤더가 있을 때만 기록합니다. 압축·전송 방식에 따라 실제 전송량과 다를 수 있으며 헤더가 없으면 표본도 없습니다.
- `first_http_429_by_vu`: 각 VU가 처음 받은 HTTP 429의 UTC 시각을 k6 로그에 기록합니다. 가장 이른 시각을 찾은 뒤 WAF 로그의 출발지 IP·규칙·action과 대조합니다. 이 시각은 부하기가 429를 처음 관측한 시각이지 AWS 내부 감지 지연 자체가 아닙니다.

## 해석 범위

이 실험은 단일 viewer IP 기준 `/api/` rate rule을 확인합니다. 여러 IP에 분산된 요청이나 SSE 장기 연결 한도는 이 스크립트의 검증 범위가 아닙니다. AWS WAF 적용, CloudFront 배포, 실제 부하 실행은 이 문서 작성 과정에서 수행하지 않았습니다.
