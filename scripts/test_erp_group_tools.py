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

    def test_2d_grid_mismatched_topo_channels_differences_and_stats_plot(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);metadata=[]
            for person,grp,chs in [('P1','CON',['Fp1','Fp2','F9','P3','P4']),('P2','ADV',['Fp1','Fp2','FT9','P3','P4'])]:
                for sess in ['03','05']:
                    subject=f'{person}SESSION{sess}';path=root/f'{subject}.ccseeg.json'
                    freq=[[1.0]*3 for _ in chs];rare=[[3.0]*3 for _ in chs]
                    record=dict(path=str(path),subject=subject,task='Custom',labels=chs,times=[-.2,0,.4],condition_names=['Freq','Rare'],channel_conditions={'Freq':freq,'Rare':rare})
                    (root/f'{subject}_erp_results.ccserp').write_text(json.dumps({'schema':'ccs-erp-workbench-v1','files':[record]}))
                    for cond in ['Freq','Rare']:
                        metadata.append(dict(filename=str(path),subjid=subject,participant_id=person,group=grp,Session=sess,Condition=cond))
            opts=dict(folder=str(root),output_dir=str(root/'plots'),metadata=metadata,subject_col='participant_id',series_factor='group',facet_factor='Session',channels='Fp1',auto_size=True,dpi=80)
            # 2D grid raw waveforms + difference waveforms
            res_erp=figures.render({**opts,'mode':'erp','plot_differences_only':True,'difference_pairs':[['Rare','Freq']]})
            self.assertTrue(all(Path(p).is_file() for p in res_erp['paths']))
            with (root/'plots/GrandAverage_erp.csv').open() as stream:
                rows=list(csv.DictReader(stream))
            self.assertEqual({r['condition'] for r in rows},{'Rare − Freq'})
            self.assertEqual(float(rows[0]['mean']),2.0)
            # Topo aligns across F9 vs FT9 without skipping P2
            res_topo=figures.render({**opts,'mode':'topo','window_start':0,'window_end':400,'plot_differences_only':True,'difference_pairs':[['Rare','Freq']]})
            self.assertTrue(all(Path(p).is_file() for p in res_topo['paths']))
            self.assertEqual(res_topo['warnings'],[])
            # Publication stats plot export
            res_stats=figures.render({
                'mode':'stats_plot','output_dir':str(root/'plots'),'output_stem':str(root/'plots/pub_stats'),'dpi':80,
                'stats_payload':{
                    'metric_label':'Mean amplitude (µV)','plot_type':'boxplot','use_sem':True,
                    'x_factor':'Session','series_factor':'group','facet_col_factor':'Condition',
                    'factor_levels':{'Session':['03','05'],'group':['CON','ADV'],'Condition':['Rare − Freq']},
                    'cell_descriptives':{
                        'Session=03|group=CON|Condition=Rare − Freq':{'values':[1.0,1.5,2.0]},
                        'Session=03|group=ADV|Condition=Rare − Freq':{'values':[0.2,0.5,0.8]},
                    },
                    'brackets_by_panel':{'All|Rare − Freq':[{'x_a':0,'x_b':0,'series_a':0,'series_b':1,'label':'CON–ADV *'}]},
                },
            })
            self.assertTrue(all(Path(p).is_file() for p in res_stats['paths']))


if __name__=='__main__':unittest.main()
