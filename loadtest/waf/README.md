# CloudFront WAF rate-limit experiment

이 실험의 목적은 현재 WAF 기준이 정상 API 사용량을 허용하면서, 한 IP에서 급증한 `/api/` 요청을 감지·제한하는지 확인하는 것입니다.

## 현재 코드 기준 가설

`app-server/waf.tf`와 `app-server/modules/api-waf/main.tf`의 현재 코드 기본값은 다음과 같습니다. 실제 배포값은 Terraform apply와 CloudFront 배포 상태를 별도로 확인합니다.

- CloudFront에 WAF 연결: `api_waf_enabled = true`
- 차단 모드: `api_waf_mode = "block"` (기준 초과 요청에 HTTP 429 반환)
- 집계 기준: viewer IP
- 적용 범위: `/api/` 경로
- 요청 기준: IP당 300초 동안 500회

500회는 실측값이 아닙니다. 모듈 주석의 가정인 `6.8회/방문 × 2회/5분 × 10명 × 3배 여유 ≈ 408회`를 500으로 올림한 값입니다.

### H1: 정상 사용자 패턴은 WAF 기준보다 낮다

- 한 k6 발생기에서 10개 VU를 실행합니다. 이 VU들은 WAF 기준상 같은 viewer IP로 집계됩니다.
- 한 번 방문할 때 읽기 API 7회를 호출하고, 각 VU가 5분 동안 2회 방문합니다.
- 예상량은 `10 VU × 2회 × 7요청 = 140요청/5분`이며 500회보다 낮습니다. 이 VU는 사용자 10명의 요청량을 대신하는 모델입니다.
- 기대 결과: 정상 API 요청 성공, 제한 기준 초과 없음, p95 응답시간이 임시 기준인 1초 이내.

현재 스크립트는 모든 VU가 한 fixture 사용자의 짧은 테스트 JWT와 계좌를 공유합니다. VU들은 WAF 기준상 같은 viewer IP로 집계됩니다. 이 구성은 IP별 요청량 가설을 확인하지만 서로 다른 사용자 데이터 분포까지 재현하지는 않습니다.

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
5. 정상 요청량이 기준 아래인지 확인하고 `api_waf_mode = "block"`을 적용한 뒤 H2/H3를 반복합니다. 관찰만 할 때는 `count`를 명시적으로 설정합니다.

`loadtest/waf/rate-limit.js`의 기본값은 `MODE=smoke`, `NORMAL_USERS=10`, `FLOOD_RPS=3`입니다. BE의 로그인은 카카오 OAuth 인가코드를 필요로 하므로, 부하테스트에서는 기존 `loadtest/k6/issue_k6_users.py`로 승인된 fixture 사용자의 짧은 테스트 JWT를 발급합니다. 이 발급기는 JWT를 출력하지 않고 권한이 제한된 파일에 저장하며, WAF 스크립트는 `ACCESS_TOKEN_FILE`에서 읽습니다. 계좌 ID는 그 사용자의 계좌 목록에서 자동으로 고릅니다. 계좌를 지정하려면 `NORMAL_ACCOUNT_ID`를 설정할 수 있습니다.

## 테스트 JWT 준비 및 실행

맥에서 기존 `stockspoon-loadtest-k6` EC2에 두 스크립트를 올립니다. `<K6_PUBLIC_IP>`는 EC2를 시작한 뒤 콘솔에서 확인한 현재 주소로 바꿉니다.

```sh
cd /Users/kimjihyeon/dev/KTB4-11th-Cloud

scp -i ~/.ssh/stockspoon-v1-deploy \
  loadtest/waf/rate-limit.js \
  ubuntu@<K6_PUBLIC_IP>:/home/ubuntu/rate-limit.js

scp -i ~/.ssh/stockspoon-v1-deploy \
  /Users/kimjihyeon/dev/KTB4-11th-BE/loadtest/k6/issue_k6_users.py \
  ubuntu@<K6_PUBLIC_IP>:/home/ubuntu/issue_k6_users.py

ssh -i ~/.ssh/stockspoon-v1-deploy ubuntu@<K6_PUBLIC_IP>
```

EC2에서 승인된 fixture 경로가 있는지 먼저 확인하고, fixture 사용자 한 명의 토큰 파일을 만듭니다. 발급기는 `JWT_SECRET`을 숨겨진 입력으로 받습니다. 비밀값을 명령 인자나 파일에 넣지 않습니다. JWT는 기본 15분 후 만료합니다.

```bash
test -r /home/ubuntu/loadtest/be-canary/.env.production-fixtures.json

python3 /home/ubuntu/issue_k6_users.py \
  --fixture /home/ubuntu/loadtest/be-canary/.env.production-fixtures.json \
  --count 1 \
  --output /home/ubuntu/.config/stockspoon-k6/waf-user.json
```

발급기가 `Type yes to continue:`를 표시하면 확인 후 `JWT_SECRET (hidden):` 프롬프트에 승인된 경로로 확인한 값을 입력합니다. 발급 파일은 권한 `0600`으로 생성됩니다. 이 token은 기존 fixture 계정에만 유효하며, 이 WAF 시나리오는 읽기 API만 호출합니다.

정상 사용자 테스트는 같은 토큰 파일로 우선 소량 확인한 뒤 기준선을 실행합니다. 두 실행은 각각 별도 k6 실행이므로 JWT 만료 15분 안에 이어서 끝냅니다.

```bash
export BASE_URL='https://stock-spoon.com'
export ACCESS_TOKEN_FILE='/home/ubuntu/.config/stockspoon-k6/waf-user.json'

MODE=smoke k6 run /home/ubuntu/rate-limit.js
MODE=normal NORMAL_USERS=10 k6 run /home/ubuntu/rate-limit.js
```

테스트가 끝나면 토큰 파일을 지웁니다.

```bash
rm -f /home/ubuntu/.config/stockspoon-k6/waf-user.json
```

`MODE=flood FLOOD_RPS=3`은 한 IP에서 기준 초과를 관찰하는 별도 H2 실행입니다. 단독 H2는 한 egress IP에서 실행할 수 있습니다. H1과 같은 IP를 재사용한다면 WAF의 300초 집계 구간이 지난 뒤 시작합니다. H1 정상 요청과 H2 flood를 동시에 비교하는 H3는 서로 다른 egress IP 두 곳에서 실행해야 합니다.

### H2: WAF Count rate-match 확인

`run-h2-count.sh`는 `/api/v1/users/me`에 3 RPS로 6분 동안 읽기 GET만 보내며, k6 로그와 JSON summary에 시작·종료 시각을 자동 기록합니다. 총 예정 요청은 1,080건이며, 완전한 5분 구간에는 약 900건이 들어가므로 IP당 500건/300초 기준 초과를 관찰할 수 있습니다. 이 runner는 AWS WAF 설정을 바꾸지 않으므로 Count 비교 실험을 할 때만 실행하고, 적용된 Web ACL이 Count 상태인지 확인합니다.

EC2에서 직전에 발급한 테스트 JWT 파일이 있어야 합니다. 토큰 발급기가 `/home/ubuntu/issue_k6_users.py`에 있고, fixture는 `/home/ubuntu/loadtest/be-canary/.env.production-fixtures.json`에 있습니다. JWT는 15분 유효하므로 발급 후 바로 실행합니다.

```bash
python3 /home/ubuntu/issue_k6_users.py \
  --fixture /home/ubuntu/loadtest/be-canary/.env.production-fixtures.json \
  --count 1 \
  --output /home/ubuntu/.config/stockspoon-k6/waf-user.json
```

발급기가 확인 문구를 표시하면 `yes`를 입력하고, `JWT_SECRET (hidden):` 프롬프트에 값을 입력해 발급을 끝냅니다. 그 다음 runner를 별도로 실행합니다.

```bash
/home/ubuntu/run-h2-count.sh
```

발급기가 `JWT_SECRET`을 입력받는 동안 다음 명령은 붙여 넣지 않습니다. 실행 결과는 `/home/ubuntu/loadtest-results/http-flood/`에 `.log`와 `-summary.json`으로 저장됩니다. Count 모드에서는 기준 초과 요청이 애플리케이션까지 계속 전달될 수 있습니다. 이 H2 실행은 별도 IP의 정상 사용자를 동시에 검증하는 H3가 아닙니다.

### H2: WAF Block 적용 후 동일 조건 비교

`run-h2-block.sh`는 Count 실험과 동일한 `/api/v1/users/me`, 3 RPS, 6분 조건으로 실행합니다. 배포된 CloudFront Web ACL을 Block 모드로 변경하고 적용이 끝난 뒤에만 실행합니다. runner는 WAF를 변경하거나 현재 모드를 조회하지 않습니다. `WAF_MODE_CONFIRMED=block`은 실행자가 배포 상태를 확인했다는 명시적 확인값입니다.

테스트 JWT는 직전에 발급해야 합니다. 토큰은 기본 15분 유효하므로 발급 후 바로 실행합니다.

```bash
WAF_MODE_CONFIRMED=block /home/ubuntu/run-h2-block.sh
```

결과는 `/home/ubuntu/loadtest-results/http-flood/` 아래 `-h2-block.log`와 `-h2-block-summary.json`으로 저장됩니다. Count 결과와 함께 2xx·429·기타 응답 비율, 지연시간, WAF `BlockedRequests`를 비교합니다. 429 응답만으로 WAF 차단을 확정하지 말고 WAF 로그에서 종료 규칙 `api-per-source-ip`를 확인합니다.

`smoke`와 `normal`은 정상 시나리오만 실행하고 `flood`는 별도 실행합니다. H3를 확인하려면 서로 다른 egress IP를 가진 두 테스트 발생기에서 동시에 실행해야 합니다. 하나의 호스트에서 터미널만 두 개 띄우면 출발지 IP가 같으므로 H3가 되지 않습니다.

### 테스트 데이터 정리

현재 `rate-limit.js`의 smoke·normal·flood 요청은 모두 HTTP GET이며, 부하테스트 JWT는 기존 fixture 사용자로 발급합니다. 이 시나리오는 사용자·계좌·주문 등의 DB 행을 생성하거나 변경하지 않으므로 삭제용 SQL은 실행하지 않습니다. k6 결과는 부하기의 결과 파일에, WAF 요청 지표와 로그는 CloudWatch에 남습니다.

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

기본 H1/H2 실행은 단일 viewer IP 기준 `/api/` rate rule을 확인합니다. 다음 H3의 혼합 테스트는 정상 IP 하나와 패턴별 공격 IP를 동시에 비교합니다. SSE 장기 연결 한도는 이 스크립트의 검증 범위가 아닙니다. AWS WAF 적용, CloudFront 배포, 실제 부하 실행은 이 문서 작성 과정에서 수행하지 않았습니다.

## H3: 정상 트래픽과 공격 패턴 동시 검증

`flood-mixed.js`는 한 실행 인스턴스에서 정상 사용자 흐름 또는 공격 패턴 하나를 실행합니다. `run-flood-mixed.sh`는 정상 IP 하나와 패턴별 공격 IP 최대 세 개를 지정해 함께 시작합니다. 공격 자체는 한 패턴당 한 IP이므로 다중 IP 봇넷을 가장하지 않습니다. 여러 IP를 쓸 때는 같은 스크립트를 각 IP에서 별도 실행하는 방식입니다.

### 근거와 각 시나리오가 나타내는 것

| `ATTACK_PROFILE` | 시나리오 | 근거와 범위 |
| --- | --- | --- |
| `capec_get` | 인증된 읽기 GET 하나를 같은 경로로 반복. 기본 3 RPS, 6분 | [MITRE CAPEC-488](https://capec.mitre.org/data/definitions/488.html)의 정상 세션형 HTTP GET Flood에 대응. 기존 H2와 같은 부하 형태를 혼합 테스트에 포함합니다. |
| `journey_flood` | 읽기 API 7개 흐름을 반복. 기본 분당 24회 방문(약 2.8 요청/초) | [AWS 애플리케이션 계층 공격 가이드](https://docs.aws.amazon.com/whitepapers/latest/aws-best-practices-ddos-resiliency/application-layer-attacks.html)가 설명하는 사용자 상호작용 모방형 Flood를 단순화해 재현합니다. |
| `burst_flood` | 단일 읽기 GET을 1 RPS에서 5 RPS까지 10초에 올리고, 150초 유지한 뒤 10초 동안 낮춤 | [Cloudflare 2025 Q3 관측](https://radar.cloudflare.com/reports/ddos-2025-q3)의 HTTP DDoS 지속 시간 통계를 참고한 제한적 단기 급증 패턴입니다. Cloudflare 관측치를 서비스 RPS 목표로 사용하지 않습니다. |

[CSE-CIC-IDS2018](https://www.unb.ca/cic/datasets/ids-2018.html)은 CSE와 Canadian Institute for Cybersecurity가 정상 사용자 B-Profile 및 공격 M-Profile을 함께 만든 연구용 자료입니다. HTTP DoS 도구·공격 시간·PCAP을 제공하며, 단일 공격 기계 시나리오도 포함합니다. 이 자료는 패턴의 출처와 실험 설계 근거로 사용하고, 공개 공격 도구를 운영 서비스에 직접 실행하지 않습니다. 여기서 선택한 세 프로필은 현재 IP별 rate rule이 대상으로 삼는 완료된 HTTP 요청의 요청률·경로 흐름을 검증합니다. Slowloris처럼 불완전한 요청을 오래 열어두는 연결 점유 시험은 별도 위협이며 이 스크립트에 포함하지 않습니다.

### 출발지 IP 조건

k6의 `--local-ips` 옵션은 OS에 이미 설정된 로컬 IP 중 하나를 VU의 출발지로 고릅니다. k6가 IP를 만들거나 `X-Forwarded-For` 값을 위조하는 기능은 아닙니다. [k6 Local IPs 문서](https://grafana.com/docs/k6/latest/using-k6/k6-options/reference/#local-ips)

`NORMAL_LOCAL_IP`와 각 `ATTACK_LOCAL_IPS`가 CloudFront WAF에서 서로 다른 viewer IP로 보여야 합니다. 같은 NAT 공개 IP로 변환되면 WAF는 동일한 소스로 집계합니다. 이 runner는 로컬 주소와 프로필을 각 k6 프로세스에 지정하지만, 실제 egress IP를 설정하거나 확인하지 않습니다. CloudFront WAF 로그에서 공격 IP별 `BLOCK`, 정상 IP의 미차단을 대조해 서로 다른 출발지임을 확인합니다.

### 실행

기존 안내대로 발급한 짧은 테스트 JWT 파일을 사용합니다. 새 두 파일을 부하 발생기에 복사합니다.

```bash
scp -i ~/.ssh/stockspoon-v1-deploy \
  loadtest/waf/flood-mixed.js \
  loadtest/waf/run-flood-mixed.sh \
  ubuntu@<K6_PUBLIC_IP>:/home/ubuntu/
```

각 로컬 주소는 실행 호스트에 이미 구성되어 있어야 하고 서로 다른 공개 egress IP로 나가야 합니다. 다음 예시는 정상 발생기 하나와 세 공격 발생기를 한 호스트에서 실행할 때의 형태입니다. 실제 주소와 대상은 승인된 시험 구성으로 대체합니다.

```bash
export BASE_URL='https://stock-spoon.com'
export ACCESS_TOKEN_FILE='/home/ubuntu/.config/stockspoon-k6/waf-user.json'
export WAF_MODE_CONFIRMED=block
export NORMAL_LOCAL_IP='<normal-local-ip>'
export ATTACK_LOCAL_IPS='<attack-ip-1>,<attack-ip-2>,<attack-ip-3>'
export ATTACK_PROFILES='capec_get,journey_flood,burst_flood'

chmod 700 /home/ubuntu/run-flood-mixed.sh
/home/ubuntu/run-flood-mixed.sh
```

runner는 정상군을 먼저 60초 실행한 뒤 공격 프로필을 동시에 시작합니다. 정상군은 기본 10 VU가 각각 읽기 GET 7개를 순회하고 약 149–159초 대기하는 흐름이라 약 140건/5분을 목표로 합니다. 각 공격원은 기본적으로 500회/300초 기준을 넘기도록 구성했습니다. `capec_get`과 `journey_flood`는 6분, `burst_flood`는 약 3분 실행됩니다(기본 약 820회 도착 예정). 정상군은 총 7분 30초 실행되어 6분 공격이 끝난 뒤 30초 회복 구간도 포함합니다. 세 공격 프로필을 모두 켜면 기본 설정에서 동시 최고 도착률은 약 11 RPS입니다. 설정값을 바꾸면 이 요청량도 달라지므로 결과 기록에 실제 값을 남깁니다.

이 runner는 한 호스트에 구성된 여러 로컬 주소를 사용합니다. 각 역할이 별도 EC2에 있다면 `flood-mixed.js`를 각 호스트에 복사하고, 정상 호스트에는 `ROLE=normal`, 공격 호스트마다 `ROLE=attack ATTACK_PROFILE=<profile>`로 각각 실행해야 합니다. 서로 다른 CloudFront viewer IP가 되도록 egress 구성을 맞추고, 실제 동시 시작은 각 호스트의 시작 시각이나 별도 실행 조정으로 맞춥니다.

세 프로필의 총량을 고려해 Block 모드에서 실행하도록 runner가 `WAF_MODE_CONFIRMED=block`을 요구합니다. 이 값은 실행자가 확인했다고 표시하는 값이며 runner가 AWS 상태를 조회하거나 바꾸지는 않습니다. 공격 발생량은 `attack_2xx_responses`, `attack_429_responses`, `dropped_iterations`로, 정상군은 성공률·p95로 확인합니다. 429가 WAF에서 나온 응답인지는 WAF 요청 로그의 종료 규칙과 출발지 IP로 확인합니다. AWS WAF의 차단 시작 시점은 설정 임계값과 정확히 일치하지 않을 수 있습니다. [AWS WAF rate rule 주의사항](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-type-rate-based-caveats.html)

현재 정상 경로 목록은 FE에서 확인한 호출 경로를 바탕으로 만든 시험 흐름이며 사용자별 요청 빈도를 측정한 운영 트래픽 프로필은 아닙니다. 운영 트래픽과의 유사성을 주장할 때는 FE HAR, CloudFront/WAF 로그 등에서 확인한 실제 경로·방문 빈도로 `NORMAL_PATHS`, `NORMAL_USERS`, `NORMAL_THINK_TIME_SECONDS`를 보정합니다.

## 요청 URL의 CloudFront·ALB 경로 분류

Terraform에서 기본 `app_dns_target`은 `cloudfront`입니다. 운영에서 실제로 적용된 값은 Terraform 변수 override와 Route 53 레코드에 따라 달라질 수 있으므로, 테스트 시점에 DNS가 CloudFront distribution을 가리키는지 확인합니다. 기존 H1/H2 결과도 `https://stock-spoon.com`을 CloudFront viewer URL로 사용했습니다.

사용자 요청 URL은 보통 같은 `https://stock-spoon.com` 도메인입니다. CloudFront가 경로에 따라 origin을 고르며, `ALB origin`은 별도의 사용자 경로가 아니라 CloudFront 뒤쪽 전달 대상입니다.

| 요청 경로 | Terraform CloudFront behavior | 최종 origin | WAF 구분 |
| --- | --- | --- | --- |
| `/` 및 일반 페이지 경로 | default → `frontend-pages` | ALB | CloudFront WAF와 ALB WAF 모두 통과 |
| `/_next/static/*` | 정적 asset behavior | S3 | CloudFront WAF만 통과, ALB에는 도달하지 않음 |
| `/api`, `/api/*` | API behavior → `application` | ALB | 둘 다 통과. 현재 rate rule은 `/api/`만 검사 |
| `/market`, `/market/*` | market behavior → `application` | ALB | 둘 다 통과. 현재 `/api/` rate rule에는 포함되지 않음 |
| ALB의 `*.elb.amazonaws.com` 주소로 직접 요청 | CloudFront를 거치지 않음 | ALB | CloudFront WAF 우회, ALB WAF만 검사 |
| market-http Task 사설 IP `:8000` 직접 접속 | CloudFront·ALB를 거치지 않음 | ECS Task | CloudFront·ALB WAF 모두 우회; SSE 애플리케이션 용량만 시험 |

FE 코드에서 `NEXT_PUBLIC_MARKET_API_BASE_URL=/market`로 빌드되므로 브라우저가 여는 SSE 주소는 `/market/prices/stream`과 `/market/orderbooks/stream`입니다. FE 코드의 `/prices/stream`, `/orderbooks/stream`은 이 base URL 뒤에 붙는 endpoint 경로입니다. 둘 다 현재 CloudFront `/market/*` behavior를 거쳐 ALB의 `application` origin으로 전달됩니다. 현재 Terraform의 `api_waf`는 CloudFront distribution에만 붙고 URI가 `/api/`로 시작하는 요청만 제한하므로, SSE는 그 rate rule로 보호되지 않습니다. ALB용 WAF는 현재 Terraform에 association이 없습니다.

계획하는 CloudFront WAF와 ALB WAF는 별도의 Web ACL입니다. CloudFront를 거쳐 ALB까지 도착한 요청은 두 ACL을 순서대로 거치며, S3 정적 asset은 CloudFront WAF만 거칩니다. ALB WAF를 추가하면 CloudFront를 우회한 직접 ALB 요청도 검사하지만, ALB WAF의 기본 client IP는 CloudFront를 통해 온 경우 마지막 proxy의 주소가 될 수 있습니다. AWS 문서상 WAF rate rule은 forwarded IP 구성을 쓸 수 있고, CloudFront는 viewer가 보낸 X-Forwarded-For가 있으면 viewer IP를 그 뒤에 덧붙입니다. 따라서 ALB WAF에서 XFF 첫 주소를 바로 신뢰하지 말고, 클라이언트가 넣은 값을 제거·정규화해 신뢰 가능한 viewer IP를 전달하는 구성이 필요합니다. [AWS WAF forwarded IP](https://docs.aws.amazon.com/waf/latest/developerguide/waf-rule-statement-forwarded-ip-address.html), [CloudFront X-Forwarded-For 동작](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/RequestAndResponseBehaviorCustomOrigin.html)

## macOS 로컬 k6 실행

로컬에는 k6 `v2.3.0`이 설치되어 있습니다. `run-local-flood.sh`는 저장소의 `flood-mixed.js`를 사용하며, 기본 `capec_get` 프로필은 인증된 읽기 API 하나에 3 RPS로 6분간 요청합니다. 실행 전에 유효기간 15분인 테스트 JWT 파일이 있어야 합니다. 아래 발급기는 API를 호출하지 않고 기존 fixture 사용자용 JWT를 로컬에서 서명합니다. `<로컬 fixture 경로>`는 승인된 부하테스트 fixture 파일 경로로 바꿉니다. JWT secret은 숨김 입력으로만 받습니다.

```bash
python3 /Users/kimjihyeon/dev/KTB4-11th-BE/loadtest/k6/issue_k6_users.py \
  --fixture '<로컬 fixture 경로>' \
  --count 1 \
  --output "$HOME/.config/stockspoon-k6/waf-user.json"
```

공격 프로필은 배포된 CloudFront Web ACL이 Block 모드임을 확인한 뒤 실행합니다. 다음 명령은 실행 예시이며 이 문서를 작성하면서 실제 요청을 보내지는 않았습니다.

```bash
cd /Users/kimjihyeon/dev/KTB4-11th-Cloud
BASE_URL='https://stock-spoon.com' \
ACCESS_TOKEN_FILE="$HOME/.config/stockspoon-k6/waf-user.json" \
WAF_MODE_CONFIRMED=block \
ATTACK_PROFILE=capec_get \
./loadtest/waf/run-local-flood.sh
```

`BASE_URL`은 `https://stock-spoon.com`처럼 CloudFront viewer 주소로 둡니다. 그러면 현재 `/api/` 테스트는 CloudFront WAF를 통과한 뒤 ALB origin까지 갑니다. runner 결과는 기본적으로 `~/.local/state/stockspoon-k6/http-flood/`에 mode `0700` 디렉터리로 저장됩니다. 단일 Mac 네트워크에서 정상군과 공격군을 각각 실행해도 외부에서 보이는 공인 IP가 같을 수 있으므로, 두 역할을 한꺼번에 돌리는 것만으로는 H3의 서로 다른 IP 비교가 되지 않습니다. H3에는 기존 `run-flood-mixed.sh`를 별도 egress IP가 있는 발생기에서 사용합니다.

정상 기준선은 같은 runner에서 `ROLE=normal`을 설정해 실행할 수 있습니다. 이 로컬 WAF runner는 HTTP `/api/`만 다루며 SSE 연결의 동시 접속 수·장시간 유지·재연결 패턴은 포함하지 않습니다. 저장소에는 별도의 SSE 클라이언트 [sse.js](../../fis/market-http/client/sse.js)가 있고, `k6/x/sse` 확장을 포함한 `k6-sse` 바이너리가 필요합니다. [전용 발생기 문서](../../test-infra/sse-k6/README.md)에 설명된 발생기는 Task 사설 IP의 `:8000`으로 직접 연결하므로 CloudFront/ALB WAF를 검증하지 않고 market-http의 SSE 처리 용량을 보는 용도입니다. WAF 검증을 하려면 SSE 스크립트의 `base_url`을 공개 CloudFront 도메인의 `/market` 경로로 설정하고, `/market/` 요청을 다루는 규칙을 별도로 시험해야 합니다. 한 SSE 요청은 장시간 연결 하나를 열 수 있으므로, HTTP 요청률 검증과 활성 연결 수·재연결률 검증은 분리합니다.
