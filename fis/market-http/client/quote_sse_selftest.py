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
 (tmp/'fake_sse.js').write_text("import payload from './payload.js'; export default {open(url, options, setup) {const handlers={}; setup({on(name, callback) {handlers[name]=callback;}, close() {}}); handlers.event({name:'price', data:JSON.stringify(payload)}); return {status:200};}};")
 (tmp/'plan.json').write_text(json.dumps({'quote_state_enabled':True,'groups':{'home_prices':{'connections':1,'stream':'prices','code_count':1}},'codes':{'prices':['Q00000']},'base_url':'https://invalid.invalid','budget_seconds':1,'retry_min_ms':1,'retry_max_ms':1,'snapshot_interval_ms':5000,'source_age_sample_every':20,'max_source_age_ms':1000,'max_future_skew_ms':100}))
 result=subprocess.run(['k6','run','--quiet',str(tmp/'sse.js')],env={**os.environ,'K6_NO_USAGE_REPORT':'true','FIS_PLAN':str(tmp/'plan.json')},capture_output=True,text=True)
 assert result.returncode==0,result.stderr
 assert 'quote_subscription' in result.stderr and 'quote_state' in result.stderr,result.stderr
 assert 'quote_measurement_error' not in result.stderr,result.stderr
 print('Main SSE hook local stub integration passed; HTTP/SSE imports replaced, no network traffic')
