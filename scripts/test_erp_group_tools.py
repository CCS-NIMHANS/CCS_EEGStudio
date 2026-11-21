"""Scientific and export regressions; synthetic data only (Python unittest)."""
import csv
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import numpy as np

os.environ.setdefault('MPLCONFIGDIR',str(Path(tempfile.gettempdir())/'ccs-erp-test-mpl'))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'assets'))
import erp_factorial_models as models
import erp_group_figures as figures


class FactorialModels(unittest.TestCase):
    def test_fitted_mixed_model_contrasts_respect_participant_cells(self):
        rng=np.random.default_rng(10);rows=[]
        for subject in range(20):
            intercept=rng.normal(0,10)
            for session in ['03','05']:
                for condition in ['Freq','Rare']:
                    y=intercept+2*(condition=='Rare')+1*(session=='05')+rng.normal(0,.25)
                    rows.append([str(subject),'A' if subject<10 else 'B',session,condition,str(y)])
        options=dict(headers=['person','group','Session','Condition','mean_uv'],rows=rows,factors=['group','Session','Condition'],metrics=['mean_uv'],subjectCol='person',preferredModel='lmm')
        result=models.analyse(options)['results'][0]
        self.assertEqual(result['n_subjects'],20)
        contrast=next(c for c in result['posthoc'] if c['factor']=='Condition' and not c['stratum'])
        self.assertAlmostEqual(contrast['mean_diff'],2,delta=.15)
        self.assertLess(contrast['p_adj'],.001)
        self.assertTrue(any(c['stratum']=={'group':'A','Session':'03'} for c in result['posthoc']))
        # Repeated identical exported rows must not increase precision or N.
        duplicate=models.analyse({**options,'rows':rows+rows})['results'][0]
        again=next(c for c in duplicate['posthoc'] if c['factor']=='Condition' and not c['stratum'])
        self.assertEqual(duplicate['n_obs'],result['n_obs'])
        self.assertAlmostEqual(again['standard_error'],contrast['standard_error'],places=8)

    def test_glm_handles_independent_people_without_lmm_label(self):
        options=dict(headers=['person','group','y'],rows=[[str(i),'A' if i<8 else 'B',str(i*.3+(i%3)*.1)] for i in range(16)],factors=['group'],metrics=['y'],subjectCol='person',preferredModel='glm')
        result=models.analyse(options)['results'][0]
        self.assertEqual(result['model_type'],'OLS GLM')
        self.assertEqual(result['test_statistic'],'F')
        self.assertEqual(len(result['posthoc']),1)


class GroupFigures(unittest.TestCase):
    def fixture(self, root):
        metadata=[]
        for number,(person,session,value) in enumerate([('P1','03',1),('P1','03',3),('P2','03',10)]):
            subject=f'{person}SESSION{session}_{number}'
            path=str(root/f'{subject}.ccseeg.json')
            labels=['Fp1','Fp2','P3','P4']
            condition=[[value]*3 for _ in labels]
            record=dict(path=path,subject=subject,task='Custom',labels=labels,times=[-.2,0,.2],condition_names=['Freq'],channel_conditions={'Freq':condition},measurements={'B_minus_A':{'mean':2,'signed_auc':.4,'peak_amplitude':5,'peak_latency':.2,'fractional_area_latency':.15}},regression={'predictors':['Class_B_minus_A'],'channels':labels,'times':[-.2,0,.2],'coefficients':[condition]},decoding={'times':[-.2,0,.2],'auc':[.5,.7,.8]})
            (root/f'{subject}_erp_results.ccserp').write_text(json.dumps({'schema':'ccs-erp-workbench-v1','files':[record]}))
            metadata.append(dict(filename=path,subjid=subject,participant_id=person,Session=session,group='A',Condition='Freq'))
        return dict(folder=str(root),output_dir=str(root/'plots'),metadata=metadata,subject_col='participant_id',series_factor='group',channels='Fp1',width=6,height=3,dpi=80)

    def test_equal_participant_weighting_and_saved_difference_peaks(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);options=self.fixture(root)
            figures.render({**options,'mode':'erp'})
            with (root/'plots/GrandAverage_erp.csv').open() as stream:rows=list(csv.DictReader(stream))
            self.assertEqual(float(rows[0]['mean']),6)
            self.assertEqual(int(rows[0]['n_participants']),2)
            result=figures.render({**options,'mode':'difference_table'})
            with open(result['csv']) as stream:rows=list(csv.DictReader(stream))
            self.assertEqual(float(rows[0]['peak_amplitude_ERP']),5)
            self.assertEqual(float(rows[0]['peak_latency_ms_ERP']),200)
            for mode in ['topo','rerp','ml']:
                result=figures.render({**options,'mode':mode,'predictor':'Class_B_minus_A','window_start':0,'window_end':200})
                self.assertTrue(all(Path(path).is_file() for path in result['paths']))

    def test_time_frequency_keeps_same_participant_in_separate_visits(self):
        engine=Path(__file__).resolve().parents[1]/'bridge/target/release/ccs-eeg-engine'
        if not engine.exists():self.skipTest('Build native engine for time-frequency integration test')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);metadata=[]
            for person in ['S1','S2']:
                for visit in ['03','05']:
                    subject=f'{person}SESSION{visit}';path=root/f'{subject}.ccseeg.json'
                    data=[]
                    for epoch in range(4):
                        data.extend([(1+(epoch%2)*3)*(np.sin(2*np.pi*10*t/128)) for t in range(128)])
                    path.write_text(json.dumps(dict(format='ccseeg-v1',sample_rate=128,labels=['Cz'],channels=[data],source_epoch_samples=128,epoch_tmin=-.2,epoch_labels=['Freq','Rare','Freq','Rare'])))
                    record=dict(path=str(path),subject=subject,task='Test',labels=['Cz'],profile={'conditions':[{'name':'Freq','codes':['Freq']},{'name':'Rare','codes':['Rare']}]})
                    (root/f'{subject}_erp_results.ccserp').write_text(json.dumps({'files':[record]}))
                    for condition in ['Freq','Rare']:metadata.append(dict(filename=str(path),subjid=subject,participant_id=person,Session=visit,Condition=condition))
            opts=dict(folder=str(root),output_dir=str(root/'plots'),metadata=metadata,subject_col='participant_id',series_factor='Session',channels='Cz',condition_a='Freq',condition_b='Rare',engine=str(engine),width=10,height=5,dpi=80)
            for mode in ['ersp','itc']:
                figures.render({**opts,'mode':mode})
                source=json.loads((root/f'plots/group_{mode}_source.json').read_text())
                self.assertEqual(len(source),2)
                self.assertEqual([v['n_subjects'] for v in source.values()],[2,2])


if __name__=='__main__':unittest.main()
