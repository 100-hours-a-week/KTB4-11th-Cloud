import copy,json,unittest
from unittest.mock import Mock
from network_runtime import list_invocations,stopped_network_namespace
from preflight import ACCOUNT,CLUSTER,REGION,SERVICE

class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.mi='mi-123';self.doc='AWSFIS-Run-Network-Packet-Loss-ECS';self.when='2026-10-27T17:00:00Z'
        self.task=f'arn:aws:ecs:{REGION}:{ACCOUNT}:task/{CLUSTER}/'+32*'a'
        self.row={'taskArn':self.task,'group':'service:'+SERVICE,'lastStatus':'STOPPED','attachments':[{'type':'ElasticNetworkInterface','status':'DELETED'}],'containers':[{'name':'market-http','lastStatus':'STOPPED'}]}
    def test_exact_filter_schema_and_full_arn(self):
        api=Mock(return_value={'CommandInvocations':[{'InstanceId':self.mi,'DocumentName':'arn:aws:ssm:region::document/'+self.doc,'Comment':'FIS-exp'}]})
        self.assertEqual(len(list_invocations(api,self.mi,self.when,self.doc,'exp')),1)
        self.assertEqual(json.loads(api.call_args.args[-1]),[{'key':'InvokedAfter','value':self.when}])
    def test_bare_name_and_experiment_scope(self):
        api=Mock(return_value={'CommandInvocations':[{'InstanceId':self.mi,'DocumentName':self.doc,'Comment':'FIS-other'}]})
        self.assertEqual(list_invocations(api,self.mi,self.when,self.doc,'exp'),[])
        self.assertEqual(len(list_invocations(api,self.mi,self.when,self.doc)),1)
    def test_other_instance_excluded(self):
        api=Mock(return_value={'CommandInvocations':[{'InstanceId':'mi-other','DocumentName':self.doc}]})
        self.assertEqual(list_invocations(api,self.mi,self.when,self.doc),[])
    def test_read_failure_not_success(self):
        with self.assertRaises(RuntimeError):list_invocations(Mock(side_effect=RuntimeError()),self.mi,self.when,self.doc)
    def test_removed_namespace(self):
        d=stopped_network_namespace(Mock(return_value={'tasks':[self.row]}),self.task)
        self.assertEqual(d['status'],'not-running');self.assertIn('DELETED',d['verification_method'])
    def test_live_task_needs_endpoint(self):
        self.row['lastStatus']='RUNNING'
        self.assertIsNone(stopped_network_namespace(Mock(return_value={'tasks':[self.row]}),self.task))
    def test_stop_without_removal_is_not_clear(self):
        for change in ['attached','running-container','no-attachment','no-container']:
            row=copy.deepcopy(self.row)
            if change=='attached':row['attachments'][0]['status']='ATTACHED'
            if change=='running-container':row['containers'][0]['lastStatus']='RUNNING'
            if change=='no-attachment':row['attachments']=[]
            if change=='no-container':row['containers']=[]
            with self.subTest(change=change),self.assertRaises(RuntimeError):stopped_network_namespace(Mock(return_value={'tasks':[row]}),self.task)
    def test_wrong_service_rejected(self):
        self.row['group']='service:backend'
        with self.assertRaises(ValueError):stopped_network_namespace(Mock(return_value={'tasks':[self.row]}),self.task)
    def test_missing_task_is_not_clear(self):
        with self.assertRaises(RuntimeError):stopped_network_namespace(Mock(return_value={'tasks':[]}),self.task)
    def test_wrong_cluster_rejected_before_api(self):
        api=Mock()
        with self.assertRaises(ValueError):stopped_network_namespace(api,self.task.replace(CLUSTER,'other'))
        api.assert_not_called()
    def test_invalid_time_and_document_rejected(self):
        for time,doc in [('2026-10-27T17:00:00',self.doc),(self.when,'AWS-RunShellScript')]:
            api=Mock()
            with self.assertRaises(ValueError):list_invocations(api,self.mi,time,doc)
            api.assert_not_called()


class DeliveryEvidenceTests(unittest.TestCase):
    def data(self, connections=10, values=None):
        labels={'task_id':'task','stream':'prices'}
        return {'end':200,'metrics':{'connections':{'data':{'result':[{'metric':labels,'values':[[100,str(connections)],[200,str(connections)]]}]}},'live_delivery_counter':{'data':{'result':[{'metric':labels,'values':values or [[100,'0'],[200,'0']]}]}}}}
    def test_idle_replacement_is_not_delivery_failure(self):
        from network_runtime import delivery_evidence
        d=self.data(values=[[100,'2'],[200,'4']]);idle=copy.deepcopy(self.data(0))
        for key in d['metrics']:
            row=idle['metrics'][key]['data']['result'][0];row['metric']['task_id']='replacement';d['metrics'][key]['data']['result'].append(row)
        result=delivery_evidence(d);self.assertEqual(result['issues'],[]);self.assertEqual(result['observed_connections'],10);self.assertEqual(len(result['idle_series']),1)
    def test_active_clients_without_events_fail(self):
        from network_runtime import delivery_evidence
        self.assertTrue(delivery_evidence(self.data())['issues'])
    def test_counter_reset_still_allows_evidence_of_progress(self):
        from network_runtime import delivery_evidence
        self.assertEqual(delivery_evidence(self.data(values=[[100,'100'],[150,'0'],[200,'5']]))['issues'],[])
    def test_no_active_clients_is_not_recovery_proof(self):
        from network_runtime import delivery_evidence
        self.assertTrue(delivery_evidence(self.data(0))['issues'])

if __name__=='__main__':unittest.main()
