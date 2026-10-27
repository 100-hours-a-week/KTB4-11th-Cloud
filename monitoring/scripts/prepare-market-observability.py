#!/usr/bin/env python3
"""Prepare an offline, opt-in market-only migration bundle. Never deploys."""
import argparse
import copy
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
SCOPE = 'environment="prod",cluster="stockspoon-v2-prod-cluster"'
APP = SCOPE + ',service_name="market-http"'
RES = SCOPE + ',ecs_service="stockspoon-v2-prod-market-http",task_id!=""'
CPU_TASK = 'sum by(task_id) (rate(container_cpu_usage_seconds_total{' + RES + '}[2m]))'
MEM_TASK = 'sum by(task_id) (container_memory_working_set_bytes{' + RES + '})'
CPU_RESERVED = 'stockspoon_ecs_task_cpu_reserved_cores{' + APP + '}'
MEM_RESERVED = 'stockspoon_ecs_task_memory_reserved_bytes{' + APP + '}'
CPU_PERCENT = f'100 * sum({CPU_TASK}) / sum({CPU_RESERVED} and on(task_id) {CPU_TASK})'
MEM_PERCENT = f'100 * sum({MEM_TASK}) / sum({MEM_RESERVED} and on(task_id) {MEM_TASK})'
RUNNING = 'stockspoon_ecs_service_running_tasks{' + APP + '}'
SUCCESS = 'stockspoon_ecs_collector_success{' + APP + '}'
AVERAGE_SSE = 'avg(sum by(task_id) (market_http_sse_connections{' + APP + '}))'


def prom_target(expr, ref="A"):
    return {"refId": ref, "expr": expr, "range": True,
            "datasource": {"type": "prometheus", "uid": "prometheus"}}


def dashboard(source):
    result = copy.deepcopy(source)
    result["templating"]["list"] = [v for v in result["templating"]["list"] if v["name"] != "service"]
    replacements = {
        2: [(RUNNING, "Running"), ('stockspoon_ecs_service_pending_tasks{' + APP + '}', "Pending")],
        3: [(CPU_PERCENT, "CPU / reserved %"), (MEM_PERCENT, "Working set / reserved %")],
        4: [('stockspoon_ecs_service_' + s + '_tasks{' + APP + '}', s.title())
            for s in ("desired", "running", "pending")],
        5: [(f'sum({CPU_TASK})', "CPU used cores"), (f'sum({CPU_RESERVED})', "CPU reserved cores")],
        6: [(f'sum({MEM_TASK}) / 1024 / 1024', "Working set MiB"),
            (f'sum({MEM_RESERVED}) / 1024 / 1024', "Memory reserved MiB")],
    }
    for panel in result["panels"]:
        if panel["id"] not in replacements:
            continue
        panel["datasource"] = {"type": "prometheus", "uid": "prometheus"}
        panel["title"] = panel["title"].replace("선택 서비스", "market-http")
        panel["targets"] = []
        for index, (expr, label) in enumerate(replacements[panel["id"]]):
            target = prom_target(expr, chr(65 + index))
            target["legendFormat"] = label
            panel["targets"].append(target)
        if panel["id"] == 3:
            panel["title"] = "market-http · CPU·Working Set / 예약량 (%)"
            panel["description"] = "cAdvisor 사용량을 ECS API Task 예약량으로 정규화합니다. Working Set은 기존 AWS/ECS MemoryUtilization과 동일한 지표가 아닙니다. 리소스 표본이 있는 Task만 분모에 매칭하며 누락은 별도 알림으로 탐지합니다."
        if panel["id"] == 5:
            panel["fieldConfig"]["defaults"]["unit"] = "cores"
        if panel["id"] == 6:
            panel["fieldConfig"]["defaults"]["unit"] = "mbytes"
    result["description"] = "시세 일반 관측은 Prometheus/Loki. Task 수·예약량은 조회 전용 ECS exporter, 사용량은 cAdvisor입니다. 자동 확장용 CloudWatch SSE 지표와 FIS 중단 알람은 별도 유지합니다. ALB 화면은 AWS 기본 지표를 계속 조회합니다."
    result["version"] = result.get("version", 1) + 1
    return result


def alerts(source):
    result = copy.deepcopy(source)
    group = next(g for g in result["groups"] if g["name"] == "stockspoon-prod-market-http")
    generated_uids = {"stockspoon-market-" + suffix for suffix in
                      ("collector", "resource-gap", "memory-gap", "sse-gap")}
    group["rules"] = [r for r in group["rules"] if r["uid"] not in generated_uids]
    expressions = {"cpu": CPU_PERCENT, "memory": MEM_PERCENT,
                   "tasks": RUNNING, "sse": AVERAGE_SSE}
    for rule in group["rules"]:
        kind = rule["uid"].rsplit("-", 1)[1]
        if kind not in expressions:
            continue
        target = rule["data"][0]
        target["datasourceUid"] = "prometheus"
        target["model"] = prom_target(expressions[kind]) | {"instant": True, "range": False}
        if kind in ("cpu", "memory", "tasks"):
            rule["noDataState"] = "Alerting"
        rule["annotations"]["description"] = {
            "cpu": "cAdvisor CPU 사용 코어 / ECS API 예약 코어의 백분율입니다. 기존 85%·10분 경고 기준을 유지하며 수집 누락도 알립니다.",
            "memory": "cAdvisor Working Set / ECS API 메모리 예약량 비율입니다. AWS MemoryUtilization과 의미가 달라 90% 기준의 운영 보정이 필요합니다. 수집 누락도 알립니다.",
            "tasks": "ECS DescribeServices의 runningCount를 Prometheus로 수집합니다. API 수집 실패를 정상 0 또는 과거 값으로 덮지 않습니다.",
            "sse": "Task별 두 스트림 연결 합계를 Task 간 평균합니다. 기존 400개 경고를 유지하며 자동 확장 목표 1,000개와 별개입니다.",
        }[kind]
    template = next(r for r in group["rules"] if r["uid"].endswith("-tasks"))
    for suffix, title, expr in [
        ("collector", "시세 ECS 메타데이터 수집 실패", f'({SUCCESS} == 0) or absent({SUCCESS})'),
        ("resource-gap", "시세 Task 자원 지표 누락", f'{RUNNING} - scalar(count({CPU_TASK}))'),
        ("memory-gap", "시세 Task 메모리 지표 누락", f'{RUNNING} - scalar(count({MEM_TASK}))'),
        ("sse-gap", "시세 Task SSE 지표 누락", f'{RUNNING} - scalar(count(up{{{APP},job="market-http-metrics"}} == 1))'),
    ]:
        rule = copy.deepcopy(template)
        rule["uid"] = "stockspoon-market-" + suffix
        rule["title"] = title
        rule["annotations"] = {"summary": title, "description": "시세 관측 누락을 정상으로 숨기지 않습니다. 메타데이터 API와 Prometheus scrape 상태를 확인하세요."}
        rule["data"][0]["model"] = prom_target(expr) | {"instant": True, "range": False}
        condition = rule["data"][2]["model"]["conditions"][0]
        condition["evaluator"] = {"type": "gt", "params": [0]}
        rule["noDataState"] = "Alerting"
        rule["for"] = "2m"
        group["rules"].append(rule)
    return result


def prepare(output, switch=False, current_alerts=None):
    if output.exists():
        raise ValueError("Output exists; use a new directory to preserve previous bundles")
    output.mkdir(parents=True)
    shutil.copytree(ROOT / "market-observability", output / "market-observability",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copyfile(ROOT / "market-observability/compose.yaml", output / "compose.market-observability.yaml")
    prometheus = (ROOT / "config/prometheus.yaml").read_text()
    prometheus += '''
  - job_name: market-ecs-metadata
    scrape_interval: 15s
    static_configs:
      - targets: ["market-ecs-exporter:9190"]
'''
    (output / "prometheus.yaml").write_text(prometheus)
    if switch:
        files = {
            "grafana/dashboards/prod/ecs-sse.json": dashboard,
            "grafana/provisioning/alerting/prod-services-rules.json": alerts,
        }
        for name, transform in files.items():
            dest = output / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            source = (current_alerts if name.endswith("prod-services-rules.json") and current_alerts
                      else ROOT / "config" / name)
            dest.write_text(json.dumps(transform(json.loads(source.read_text())),
                                       ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--phase", choices=["collector", "switch"], default="collector")
    parser.add_argument("--current-alerts", type=Path,
                        help="Copy of the currently provisioned prod-services-rules.json; required for switch to preserve live pause/routing state")
    args = parser.parse_args()
    if args.phase == "switch" and not args.current_alerts:
        parser.error("--phase switch requires --current-alerts from the deployed server; do not overwrite live BE alert configuration with repository defaults")
    prepare(args.output, switch=args.phase == "switch", current_alerts=args.current_alerts)
    print(f"Prepared {args.phase} bundle at {args.output}. No AWS/deployment command was executed.")


if __name__ == "__main__":
    main()
