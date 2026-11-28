#!/usr/bin/env python3
"""Render the DB FIS dashboard, with missing evidence kept visible as missing."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
DB = 'job=~"mysql-(primary|private-replica)"'
BE = 'environment="prod",job="backend-metrics",service_name="backend",task_id!=""'
panels = []
y = 0


def row(title):
    global y
    panels.append({"id": len(panels) + 1, "type": "row", "title": title,
                   "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})
    y += 1


def chart(title, targets, description="", unit="short", kind="timeseries", x=0, width=12, height=8):
    panel = {"id": len(panels) + 1, "type": kind, "title": title, "description": description,
             "datasource": PROM, "gridPos": {"x": x, "y": y, "w": width, "h": height},
             "fieldConfig": {"defaults": {"unit": unit, "noValue": "미수집 / 이벤트 없음"}, "overrides": []},
             "options": {"legend": {"displayMode": "table", "placement": "bottom", "calcs": ["lastNotNull", "max"]}},
             "targets": [{"refId": chr(65 + i), "expr": expr, "legendFormat": legend,
                          "datasource": PROM, "range": kind != "stat", "instant": kind == "stat"}
                         for i, (expr, legend) in enumerate(targets)]}
    if kind == "stat":
        panel["options"] = {"reduceOptions": {"calcs": ["lastNotNull"], "values": False},
                            "colorMode": "value", "graphMode": "none", "textMode": "auto"}
    panels.append(panel)


def main():
    global y
    row("DB FIS · 관측 상태와 자동 복구 사전조건")
    chart("쓰기가 가능한 MySQL 노드 수 · 정상 1", [('stockspoon:mysql_writable_nodes', '관측 writer 수')],
          "수집된 read_only=0 노드 수다. MySQL 수집 실패 패널과 함께 판단한다.", kind="stat", width=6, height=5)
    chart("Replica 기본 사전조건 충족 수", [('count(stockspoon:mysql_replica_basic_preconditions) or vector(0)', '기본 조건 충족')],
          "I/O·SQL thread ON, native lag=0, Semi-sync replica ON. Repman 최종 선출 판정은 아니다.", kind="stat", x=6, width=6, height=5)
    chart("Repman 최근 인증 오류 이벤트", [('count(stockspoon_db_fis_repman_server_state{state="ErrorAuth"}) or (0 * max(stockspoon_db_fis_observer_source_up{source="repman_logs"} == 1))', '최근 ErrorAuth 노드')],
          "최근 90초 이내 로그에서 관측한 오류다. 0만으로 인증 정상이나 승격 가능을 증명하지 않는다. 아래 로그 수집 상태도 확인한다.", kind="stat", x=12, width=6, height=5)
    chart("수집 상태 · 1=수집 성공", [('up{job=~"mysql-(primary|private-replica)|proxysql-fargate|db-fis-observer"}', '{{job}}'),
          ('stockspoon_db_fis_observer_source_up', '{{source}}')], kind="stat", x=18, width=6, height=5)
    y += 5
    row("고객 영향 · 실제 DB 요청과 연결 풀")
    chart("API 작업별 p95 · 읽기/쓰기 URI로 구분", [(f'histogram_quantile(0.95,sum by(le,uri,method)(rate(http_server_requests_seconds_bucket{{{BE},uri!~"/actuator.*"}}[1m])))', '{{method}} {{uri}}')],
          "서버 계측 지연이다. 클라이언트 timeout·전송 실패는 외부 probe에서 별도 기록한다. HTTP 202는 DB 커밋 완료가 아니다.", "s")
    chart("API 5xx 요청률", [(f'sum by(uri,method)(rate(http_server_requests_seconds_count{{{BE},uri!~"/actuator.*",status=~"5.."}}[1m]))', '{{method}} {{uri}}')], unit="reqps", x=12)
    y += 8
    chart("Hikari 연결 대기 요청 수", [(f'hikaricp_connections_pending{{{BE}}}', '{{task_id}} {{pool}}')])
    chart("Hikari 연결 획득 p95", [(f'histogram_quantile(0.95,sum by(le,task_id,pool)(rate(hikaricp_connections_acquire_seconds_bucket{{{BE}}}[1m])))', '{{task_id}} {{pool}}')],
          "DB 연결 획득 대기시간이다. SQL 실행시간을 뜻하지 않는다.", "s", x=12)
    y += 8
    chart("Hikari 연결 획득 timeout 증가량 · 1분", [(f'sum by(task_id,pool)(increase(hikaricp_connections_timeout_total{{{BE}}}[1m]))', '{{task_id}} {{pool}}')])
    chart("ProxySQL backend 연결 획득 실패 · 1분", [('sum by(instance)(increase(proxysql_connpool_get_conn_failure_total{job="proxysql-fargate"}[1m]))', '{{instance}}')], x=12)
    y += 8
    row("DB 역할·복제·Semi-sync 실제 동작")
    chart("DB read_only · 0=writer / 1=replica", [(f'mysql_global_variables_read_only{{{DB}}}', '{{db_node}}')])
    chart("ProxySQL backend 상태 · 1=ONLINE", [('proxysql_connpool_conns_status{job="proxysql-fargate"}', 'HG{{hostgroup}} {{endpoint}}')], x=12)
    y += 8
    chart("Semi-sync 실제 동작 상태 · ON=1", [('stockspoon:mysql_semisync_source_status', '{{db_node}} source'),
          ('stockspoon:mysql_semisync_replica_status', '{{db_node}} replica')],
          "enabled 설정이 아닌 실제 STATUS다. 승격 후 새 writer의 source 상태도 확인한다. 없는 시계열은 0으로 채우지 않는다.")
    chart("Replica I/O · SQL 스레드", [(f'mysql_slave_status_replica_io_running{{{DB}}}', '{{db_node}} I/O'),
          (f'mysql_slave_status_replica_sql_running{{{DB}}}', '{{db_node}} SQL')], x=12)
    y += 8
    chart("복제 지연 · heartbeat와 native", [('mysql:heartbeat_lag_seconds', '{{db_node}} heartbeat'),
          (f'mysql_slave_status_seconds_behind_source{{{DB}}}', '{{db_node}} native')],
          "Repman의 native 지연 허용 설정은 0초다. 두 지표 모두 RPO 실측값을 대신하지 않는다.", "s")
    chart("Semi-sync ACK 없는 커밋 / async 전환 증가량 · 1분", [(f'increase(mysql_global_status_rpl_semi_sync_source_no_tx{{{DB}}}[1m])', '{{db_node}} ACK 없는 commit'),
          (f'increase(mysql_global_status_rpl_semi_sync_source_no_times{{{DB}}}[1m])', '{{db_node}} async 전환')],
          "현재 source 플러그인의 누적 counter 증가량. 과거 이름 master_no_tx/master_no_times는 별도 검토한다.", x=12)
    y += 8
    row("복구 이벤트 · 원본 시각과 샘플 관측 시각")
    chart("Repman 노드 Failed 상태 원본 시각", [('stockspoon_db_fis_event_timestamp_seconds{event="repman_node_failed"} * 1000', '{{endpoint}}')],
          "Repman native state log의 시각이다. 대상이 Primary였는지는 장애 직전 DB 역할과 대조한다. 과거 마지막 이벤트이며 이번 실험과 run ledger에서 연결한다.", "dateTimeAsIso", "stat", width=8, height=5)
    chart("Repman 전환 절차 완료 원본 시각", [('stockspoon_db_fis_event_timestamp_seconds{event="repman_switch_complete"} * 1000', '{{endpoint}}')],
          "Master switch complete 원본 로그. 계획 전환도 같은 메시지를 쓰므로 자동 failover 여부는 실험 원장으로 확인한다. 고객 복구 시각과 다르다.", "dateTimeAsIso", "stat", x=8, width=8, height=5)
    chart("ProxySQL writer 변경 관측 시각", [('stockspoon_db_fis_event_timestamp_seconds{event="proxysql_writer_observed"} * 1000', '{{endpoint}}')],
          "5초 scrape의 새 writer 표본 시각. 실제 전환 순간이나 SQL commit 성공을 뜻하지 않는다. 이전 표본 시각은 이벤트 원장에 남긴다.", "dateTimeAsIso", "stat", x=16, width=8, height=5)
    y += 5
    panels.append({"id": len(panels) + 1, "type": "logs", "title": "DB FIS 구조화 이벤트 원장",
                   "datasource": LOKI, "gridPos": {"x": 0, "y": y, "w": 24, "h": 9},
                   "targets": [{"refId": "A", "expr": '{job="db-fis",environment="prod"} | json', "datasource": LOKI}],
                   "options": {"showTime": True, "sortOrder": "Descending", "wrapLogMessage": True, "showLabels": False}})
    y += 9
    panels.append({"id": len(panels) + 1, "type": "text", "title": "RTO/RPO 증거와 미연결 항목",
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 6}, "options": {"mode": "markdown", "content":
                   "**RTO/RPO 목표는 조직이 정한다.** 이 화면의 승격·writer 변경 시각만으로 고객 RTO나 RPO를 산출하지 않는다.\n\n"
                   "외부 SQL probe의 commit 성공 시각과 ALB→BE API probe의 정상 복구 시각은 `run_id`가 있는 별도 JSONL 원장에 남겨야 한다. "
                   "현재 probe는 연결하지 않았으며 RTO/RPO 0으로 표시하지 않는다. FIS 자체 로그는 action 시작·종료 증거다.\n\n"
                   "RPO는 허용 데이터 손실의 **시간 목표**다. 장애 전 접수·내구성 확보·DB commit·응답 시각을 구분하고 복구 지점과 대사한다. "
                   "유실 건수·불명확한 commit·중복은 별도의 무결성 결과로 보고한다. 상세: 저장소 `fis/database/OBSERVABILITY.md`."}})
    doc = {"uid": "stockspoon-db-fis", "title": "DB FIS · 고객 영향과 자동 복구", "schemaVersion": 39,
           "version": 1, "editable": False, "tags": ["stockspoon", "database", "fis"],
           "timezone": "Asia/Seoul", "refresh": "5s", "graphTooltip": 1,
           "time": {"from": "now-30m", "to": "now"}, "panels": panels,
           "annotations": {"list": [{"name": "DB recovery events", "enable": True, "iconColor": "purple",
                                      "datasource": LOKI, "expr": '{job="db-fis",environment="prod"} | json | event!="repman_server_state"',
                                      "tagKeys": "event,endpoint", "textFormat": "{{event}} {{endpoint}}"}]}}
    path = ROOT / "config/grafana/dashboards/db-migration/db-fis.json"
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
