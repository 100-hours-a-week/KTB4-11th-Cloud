import pathlib,tempfile,subprocess,json,os
root=pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory() as directory:
 tmp=pathlib.Path(directory)
 text=(root/'sse.js').read_text().replace("import sse from 'k6/x/sse';", "import sse from './fake_sse.js';").replace("import http from 'k6/http';", "import http from './fake_http.js';")
 a=text.index('export const options =');b=text.index('const errors =',a)
 text=text[:a]+"export const options = {scenarios: {home_prices: {executor: 'shared-iterations', vus: 1, iterations: 1}}};\n"+text[b:]
 (tmp/'sse.js').write_text(text)
 (tmp/'quote_state.js').write_text((root/'quote_state.js').read_text())
 payload=json.loads((root/'quote-fixtures.json').read_text())[0]['payload']
 (tmp/'payload.js').write_text('export default '+json.dumps(payload)+';')
 (tmp/'fake_http.js').write_text("import payload from './payload.js'; export default {get() { return {status:200, json() {return [payload];}}; }};")
 (tmp/'fake_sse.js').write_text("import payload from './payload.js'; export default {open(url, options, setup) {const handlers={}; setup({on(name, callback) {handlers[name]=callback;}, close() {}}); if (handlers.open) handlers.open(); handlers.event({name:'price', id:'1', data:JSON.stringify(payload)}); handlers.event({name:'price', id:'2', data:JSON.stringify({...payload,timestamp:'2026-10-29T00:00:00.123456788Z'})}); handlers.event({name:'price',id:'3',data:JSON.stringify(payload)}); return {status:200};}};")
 (tmp/'plan.json').write_text(json.dumps({'quote_state_enabled':True,'groups':{'home_prices':{'connections':1,'stream':'prices','code_count':1}},'codes':{'prices':['Q00000']},'base_url':'https://invalid.invalid','budget_seconds':1,'retry_min_ms':1,'retry_max_ms':1,'snapshot_interval_ms':5000,'source_age_sample_every':20,'max_source_age_ms':1000,'max_future_skew_ms':100}))
 result=subprocess.run(['k6','run','--quiet','--address','','--log-format','raw',str(tmp/'sse.js')],env={**os.environ,'K6_NO_USAGE_REPORT':'true','FIS_PLAN':str(tmp/'plan.json')},capture_output=True,text=True)
 assert result.returncode==0,result.stderr
 assert 'quote_subscription' in result.stderr and 'quote_state' in result.stderr,result.stderr
 assert 'quote_measurement_error' not in result.stderr,result.stderr
 events=[json.loads(line.split('FIS_EVENT ',1)[1]) for line in (result.stdout+'\n'+result.stderr).splitlines() if 'FIS_EVENT ' in line]
 detail=next(row for row in events if row['kind']=='quote_regression')
 assert detail['client_id']=='1' and detail['group']=='home_prices'
 assert detail['attempt']==1 and detail['received']['attempt']==1
 assert detail['received']['code_payload_index']==2 and detail['received']['session_payload_index']==2
 assert detail['previous']['event_id']=='1' and detail['received']['event_id']=='2'
 assert detail['received']['session_started_ms']<=detail['received']['session_headers_ms']<=detail['received']['session_connected_ms']<=detail['at_ms']
 assert detail['state_rolled_back'] is True
 plan=json.loads((tmp/'plan.json').read_text());plan['quote_state_enabled']=False;(tmp/'plan.json').write_text(json.dumps(plan))
 disabled=subprocess.run(['k6','run','--quiet','--address','','--log-format','raw',str(tmp/'sse.js')],env={**os.environ,'K6_NO_USAGE_REPORT':'true','FIS_PLAN':str(tmp/'plan.json')},capture_output=True,text=True)
 assert disabled.returncode==0,disabled.stderr
 assert 'quote_regression' not in disabled.stderr and 'quote_state' not in disabled.stderr
 print('Main SSE hook local stub integration passed; HTTP/SSE imports replaced, no network traffic')
