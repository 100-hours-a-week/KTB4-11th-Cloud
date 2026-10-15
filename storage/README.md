# Shared Storage

애플리케이션 서버와 독립적으로 사용하는 공유 저장소를 관리한다.

## 주식 로고 버킷

- 버킷 이름: `stockspoon-stock-logos-<AWS_ACCOUNT_ID>`
- 퍼블릭 접근 차단
- ACL 비활성화(`BucketOwnerEnforced`)
- SSE-S3 암호화
- 객체 버전 관리
- 비보안 HTTP 요청 거부
- Terraform 삭제 방지

CloudFront와 Route 53 연결은 이 root의 현재 범위에 포함하지 않는다. 객체 접근 권한은 `iam` root에서 관리한다.
