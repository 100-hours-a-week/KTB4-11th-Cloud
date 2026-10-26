#!/usr/bin/env python3
"""Read the local Grafana market dashboard and a small set of live metric queries.

Run on the monitoring EC2 through SSM. Credentials stay on that server. Only
localhost HTTP GETs are made; no provisioning, reload or alert changes occur.
"""
import base64
import datetime as dt
import json
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

APP = 'environment="prod",cluster="stockspoon-v2-prod-cluster",service_name="market-http"'
QUERIES = {
    "scraped_tasks": 'count(up{' + APP + ',job="market-http-metrics"} == 1)',
    "sse_connections": 'sum by(task_id,stream) (market_http_sse_connections{' + APP + '})',
    "cpu_cores": 'sum by(task_id) (rate(container_cpu_usage_seconds_total{environment="prod",'
                 'ecs_service="stockspoon-v2-prod-market-http",task_id!=""}[2m]))',
    "memory_bytes": 'sum by(task_id) (container_memory_working_set_bytes{environment="prod",'
                    'ecs_service="stockspoon-v2-prod-market-http",task_id!=""})',
    "running_tasks": 'stockspoon_ecs_service_running_tasks{' + APP + '}',
    "valkey_pool": 'sum by(task_id,state) (market_http_valkey_pool_connections{' + APP + '})',
    "source_age_seconds": 'market_streamer_market_data_age_seconds{environment="prod",'
                          'service_name="market-streamer"}',
}


def main():
    password = Path('/srv/stockspoon-telemetry/secrets/grafana_admin_password').read_text().strip()
    authorization = 'Basic ' + base64.b64encode(('admin:' + password).encode()).decode()

    def get(path):
        request = Request('http://127.0.0.1:3000' + path, headers={'Authorization': authorization})
        with urlopen(request, timeout=15) as response:
            return json.load(response)

    dashboard = get('/api/dashboards/uid/stockspoon-ecs-sse')['dashboard']
    result = {
        'captured_at': dt.datetime.now(dt.timezone.utc).isoformat(),
        'dashboard_uid': dashboard['uid'], 'title': dashboard['title'],
        'panels': [{'id': p['id'], 'title': p['title'], 'datasource': p.get('datasource'),
                    'queries': [t.get('expr', t.get('metricName')) for t in p.get('targets', [])]}
                   for p in dashboard['panels']],
        'metrics': {},
        'scope': 'read-only local Grafana GET; no client traffic or AWS mutations',
    }
    for name, query in QUERIES.items():
        try:
            response = get('/api/datasources/proxy/uid/prometheus/api/v1/query?' + urlencode({'query': query}))
            result['metrics'][name] = {'status': response['status'],
                                       'series': response.get('data', {}).get('result', [])}
        except Exception as error:
            result['metrics'][name] = {'error': type(error).__name__}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
