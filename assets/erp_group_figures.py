"""Participant-weighted ERP publication figures from saved ccserp results.

No statistical significance is inferred from grand averages. Repeated recordings
within the same participant/cell are averaged before between-participant SEM.
Time grids must match; incompatible records are reported rather than resampled.
"""
import csv
import itertools
import json
from pathlib import Path
import re
import subprocess
import signal
import sys
import tempfile
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.interpolate import griddata
from scipy import stats
from group_stats import check_topoplot_suitability


_active_engine=None

def stop_engine(_signal, _frame):
    if _active_engine is not None:
        _active_engine.terminate()
        try:_active_engine.wait(timeout=3)
        except subprocess.TimeoutExpired:_active_engine.kill()
    raise SystemExit(143)

def run_engine(engine,path):
    global _active_engine
    _active_engine=subprocess.Popen([engine,str(path)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    try:
        stdout,stderr=_active_engine.communicate()
        if _active_engine.returncode:raise ValueError(stderr[-4000:])
        return json.loads(stdout)
    finally:_active_engine=None

def participant(value):
    return re.sub(r'(?i)(?:_?SESSION|_?SES[-_]?)[0-9]+.*$', '', str(value))


def read_records(options):
    folder = Path(options['folder'])
    paths = sorted(folder.glob('*_erp_results.ccserp'))
    if not paths:
        paths = sorted(folder.glob('*.ccserp'))
    if not paths and (folder / 'erp_results.json').exists():
        paths = [folder / 'erp_results.json']
    metadata = options.get('metadata', [])
    subjects = {str(row.get('subjid', '')) for row in metadata if row.get('subjid')}
    if subjects:
        selected = [path for path in paths if any(path.stem.startswith(value + '_') for value in subjects)]
        if selected: paths = selected
    seen = set()
    for path in paths:
        with path.open(encoding='utf-8') as stream:
            payload = json.load(stream)
        for record in payload.get('files', []):
            identity = (record.get('path'), record.get('task'), record.get('subject'))
            if identity in seen:
                continue
            seen.add(identity)
            matches = [row for row in metadata if str(row.get('filename', '')) == record.get('path') or str(row.get('subjid', '')) == record.get('subject')]
            if not matches:
                continue  # Never guess cohort membership from directory order.
            yield record, matches


def render(options):
    output = Path(options['output_dir'])
    output.mkdir(parents=True, exist_ok=True)
    mode = options.get('mode', 'erp')
    records = list(read_records(options))
    if not records:
        raise ValueError('No saved ERP results match the reviewed measurement rows. Choose the folder containing the matching .ccserp files.')
    factor_labels = options.get('factor_labels', {})
    aliases = options.get('level_labels', {})
    label = lambda factor, value: aliases.get(factor, {}).get(value, value)
    excluded = options.get('excluded_levels', {})
    metadata_allowed = lambda row: all(str(row.get(f, '')) not in values for f, values in excluded.items())
    series_factor = options.get('series_factor')
    facet_factor = options.get('facet_factor')
    row_factor = options.get('row_factor')
    factor_value = lambda row, factor: str(row.get(factor, 'All')) if factor else 'All'
    grouping = lambda row: (factor_value(row, row_factor), factor_value(row, facet_factor), factor_value(row, series_factor))
    subject_col = options.get('subject_col') or 'participant_id'
    subject = lambda row, record: str(row.get(subject_col) or participant(record.get('subject', record.get('path'))))
    if mode == 'difference_table':
        rows = []
        for record, matches in records:
            allowed = [row for row in matches if metadata_allowed(row)]
            if not allowed:
                continue
            measure = record.get('measurements', {}).get('B_minus_A')
            if not measure:
                continue
            row = dict(allowed[0])
            row.update(filename=record['path'], participant_id=subject(row, record), Condition='B_minus_A')
            for key, source, scale in [('mean_amplitude_ERP','mean',1),('signed_auc_ERP','signed_auc',1),('peak_amplitude_ERP','peak_amplitude',1),('peak_latency_ms_ERP','peak_latency',1000),('fractional_area_latency_ms_ERP','fractional_area_latency',1000)]:
                row[key] = measure.get(source, '')
                if isinstance(row[key], (float, int)):
                    row[key] *= scale
            rows.append(row)
        if not rows:
            raise ValueError('No saved B-minus-A waveform measurements found. Compute the ERP difference in Measure ERP first.')
        path = output / 'ERP_difference_group_input.csv'
        with path.open('w',newline='',encoding='utf-8') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(rows[0]))
            writer.writeheader(); writer.writerows(rows)
        return dict(csv=str(path),n_records=len(rows),method='Saved B_minus_A waveform measurements, not subtraction of peak/latency scalars')

    conditions = list(dict.fromkeys(str(row.get('Condition', '')) for _, matches in records for row in matches if metadata_allowed(row) and row.get('Condition')))
    conditions = [v for v in conditions if v not in ['B_minus_A','B - A']]
    if mode in ['rerp', 'ml']:
        conditions = [options.get('predictor', 'class') if mode == 'rerp' else 'AUC']
    order = options.get('level_order', {})
    def ordered(values, factor):
        values = set(values)
        preferred = order.get(factor, [])
        return [v for v in preferred if v in values]+sorted(values-set(preferred))
    conditions = ordered(conditions, 'Condition')
    channels = [v.strip().lower() for v in options.get('channels', 'Cz').split(',') if v.strip()]
    accumulated = {}
    grids = {}
    warnings = []
    tf_inputs = []
    tf_groups = {}
    tf_tmins = {}
    tf_counts = {}
    for record, matches in records:
        used = set()
        for row in matches:
            if not metadata_allowed(row):
                continue
            group = grouping(row)
            person = subject(row, record)
            if mode in ['ersp', 'itc']:
                if (group,person) in used:
                    continue
                used.add((group,person))
                requested={v.strip().lower() for v in options.get('channels','Cz').split(',') if v.strip()}
                if not requested.issubset({str(v).lower() for v in record.get('labels',[])}):
                    warnings.append(f'Missing requested TF ROI channels: {record.get("subject")}')
                    continue
                code = json.dumps(group)
                tf_groups[code] = group
                epoch=record.get('profile',{}).get('epoch')
                if epoch:tf_tmins.setdefault(code,set()).add(float(epoch[0])*1000)
                tf_inputs.append(dict(path=record['path'],subject=person,group=code,
                    condition_a_labels=next((c.get('codes', [c['name']]) for c in record.get('profile',{}).get('conditions',[]) if c['name']==options.get('condition_a','Freq')),[options.get('condition_a','Freq')]),
                    condition_b_labels=next((c.get('codes', [c['name']]) for c in record.get('profile',{}).get('conditions',[]) if c['name']==options.get('condition_b','Rare')),[options.get('condition_b','Rare')])))
                accepted=record.get('accepted_events',[])
                if accepted:
                    duration=float(accepted[0].get('epoch_end_s',0))-float(accepted[0].get('epoch_start_s',0))
                    if duration>0 and all(abs(float(event.get('epoch_start_s',0))/duration-round(float(event.get('epoch_start_s',0))/duration))<1e-4 for event in accepted):
                        item=tf_inputs[-1]
                        for kind in ['a','b']:
                            name=options.get('condition_'+kind, 'Freq' if kind=='a' else 'Rare')
                            accepted_labels=set(item['condition_'+kind+'_labels'])|{name}
                            item['condition_'+kind+'_trials']=sorted({round(float(event['epoch_start_s'])/duration) for event in accepted if event.get('label') in accepted_labels})
                        if not item['condition_a_trials'] or not item['condition_b_trials']:
                            warnings.append(f'Missing accepted A/B trials: {record.get("subject")}')
                            tf_inputs.pop()
                continue
            condition = str(row.get('Condition', ''))
            if mode in ['erp','topo'] and condition not in conditions:
                continue
            if mode in ['rerp','ml']:
                condition=conditions[0]
            if (group,person,condition) in used:
                continue
            used.add((group,person,condition))
            times=np.asarray(record.get('times', []),dtype=float)*1000
            labels=record.get('labels', [])
            if mode in ['erp','topo']:
                data=np.asarray(record.get('channel_conditions', {}).get(condition, []),dtype=float)
                if data.shape != (len(labels),len(times)):
                    warnings.append(f'Missing channel waveforms: {record.get("subject")} / {condition}')
                    continue
                if mode=='topo':
                    mask=(times>=options.get('window_start',300)) & (times<=options.get('window_end',600))
                    if not mask.any():
                        continue
                    data=data[:,mask].mean(axis=1)
                else:
                    picks=[i for i,name in enumerate(labels) if name.lower() in channels]
                    if len(picks)!=len(channels):
                        warnings.append(f'Missing requested ROI channels: {record.get("subject")}')
                        continue
                    data=data[picks].mean(axis=0)
            else:
                model=record.get('regression' if mode=='rerp' else 'decoding')
                if not model:
                    warnings.append(f'No saved {mode}: {record.get("subject")}')
                    continue
                times=np.asarray(model.get('times',[]),dtype=float)*1000
                if mode=='ml':
                    data=np.asarray(model.get('auc',[]),dtype=float)
                else:
                    predictors=model.get('predictors',[])
                    wanted=options.get('predictor','class')
                    if wanted not in predictors:
                        warnings.append(f'Predictor {wanted} absent in {record.get("subject")} (available: {predictors})')
                        continue
                    picks=[i for i,name in enumerate(model.get('channels',[])) if name.lower() in channels]
                    if not picks:
                        continue
                    data=np.asarray(model['coefficients'][predictors.index(wanted)],dtype=float)[picks].mean(axis=0)
            key=group+(condition,)
            grid=(tuple(labels) if mode=='topo' else tuple(times))
            if key in grids and grids[key] != grid:
                warnings.append(f'Incompatible channel/time grid skipped: {record.get("subject")}')
                continue
            grids[key]=grid
            accumulated.setdefault((key,person),[]).append(data)
    if mode in ['ersp','itc']:
        if not tf_inputs:
            raise ValueError('No matching epoch recordings for grouped time-frequency computation.')
        conditions=[options.get('condition_a','Freq'),options.get('condition_b','Rare'),'B − A']
        sources={}
        for code, group in tf_groups.items():
            # A participant may have several within-person grouping levels. Run
            # each displayed cell separately; the engine collapses sessions by
            # participant within a call, so mixing cells would erase visits.
            selected_inputs=[v for v in tf_inputs if v['group']==code]
            if not selected_inputs:continue
            starts=tf_tmins.get(code,set())
            if len(starts)>1:raise ValueError('Incompatible epoch starts in a displayed TF cell; harmonize epochs before averaging.')
            job=dict(job_type='group_ersp_itc',epoch_tmin_ms=next(iter(starts)) if starts else None,inputs=selected_inputs,channel_name='ROI',roi_channels=[v.strip() for v in options.get('channels','Cz').split(',')],fmin_hz=options.get('fmin',2),fmax_hz=options.get('fmax',40),n_freqs=options.get('n_freqs',24),baseline_start_ms=options.get('baseline_start',-200),baseline_end_ms=options.get('baseline_end',0),n_perm=20)
            with tempfile.TemporaryDirectory(dir=output,prefix='tf_work_') as temp:
                path=Path(temp)/'job.json';path.write_text(json.dumps(job),encoding='utf-8')
                tf=run_engine(options['engine'],path)
            sources[code]=tf
            tf_counts[group]=tf['n_subjects']
            for condition,field in zip(conditions,[f'{mode}_a_db' if mode=='ersp' else 'itc_a',f'{mode}_b_db' if mode=='ersp' else 'itc_b','ersp_diff_db' if mode=='ersp' else 'itc_diff']):
                values=tf.get(field)
                if values is not None:
                    key=group+(condition,)
                    accumulated[(key,'grand')]=[np.asarray(values).reshape(len(tf['freqs_hz']),len(tf['times_ms']))]
                    grids[key]=tuple(tf['times_ms'])
            warnings.extend(str(v) for v in tf.get('failed_files',[]))
        (output/f'group_{mode}_source.json').write_text(json.dumps(sources),encoding='utf-8')
    cells={}
    for (key,person),data in accumulated.items():
        cells.setdefault(key,[]).append(np.stack(data).mean(axis=0))
    if not cells:
        raise ValueError(f'No valid {mode} data in selected results. '+ '; '.join(warnings[:6])+'. Models must be computed from epochs before their coefficients or decoding scores can be averaged.')
    rows=ordered([key[0] for key in cells],row_factor)
    facets=ordered([key[1] for key in cells],facet_factor)
    series=ordered([key[2] for key in cells],series_factor)
    plt.rcParams.update({'font.size':options.get('font_size',10),'svg.fonttype':'none','pdf.fonttype':42})
    ncols=len(facets)*len(conditions)
    fig,axes=plt.subplots(len(rows),ncols,squeeze=False,sharey=mode in ['erp','rerp','ml'],figsize=(options.get('width',max(8,3*ncols)),options.get('height',max(3,3*len(rows)))),layout='constrained')
    palette=options.get('colors',{})
    default=['#0072B2','#D55E00','#009E73','#CC79A7','#E69F00','#56B4E9']
    export_rows=[]
    limit=options.get('color_limit')
    if mode=='topo' and not limit:
        limit=max(abs(np.stack(values).mean(axis=0)).max() for values in cells.values()) or 1
    for ri,row in enumerate(rows):
        for fi,facet in enumerate(facets):
            for ci,condition in enumerate(conditions):
                ax=axes[ri,fi*len(conditions)+ci]
                found=False
                for si,serie in enumerate(series):
                    key=(row,facet,serie,condition)
                    if key not in cells:
                        continue
                    values=np.stack(cells[key]);mean=values.mean(axis=0)
                    sem=values.std(axis=0,ddof=1)/np.sqrt(len(values)) if len(values)>1 else np.zeros_like(mean)
                    color=palette.get(serie,default[si%len(default)])
                    if isinstance(color,int): color=f'#{color&0xffffff:06x}'
                    name=f'{label(series_factor,serie)} (n={tf_counts.get(key[:3],len(values))})'
                    if mode=='topo':
                        # Multiple cohorts get separate maps, rather than overpainting one scalp.
                        if len(series)>1:
                            # Allocate a horizontal strip of inset scalp axes within this cell.
                            map_ax=ax.inset_axes([si/len(series),.12,1/len(series),.75])
                            map_ax.set_title(name,fontsize=8)
                        else:map_ax=ax
                        labels=list(grids[key]);ok,positions=check_topoplot_suitability(labels)
                        if not ok:raise ValueError('Topography needs at least four recognized scalp electrodes with spatial coverage.')
                        xy=np.asarray(list(positions.values()));z=np.asarray([mean[labels.index(ch)] for ch in positions])
                        radius=max(np.sqrt((xy**2).sum(axis=1)).max(),.5)*1.03
                        xx,yy=np.mgrid[-radius:radius:100j,-radius:radius:100j]
                        zz=griddata(xy,z,(xx,yy),method='cubic')
                        zz=np.ma.masked_where(xx**2+yy**2>radius**2,zz)
                        image=map_ax.pcolormesh(xx,yy,zz,cmap=options.get('colormap','RdBu_r'),vmin=-limit,vmax=limit,shading='auto',rasterized=True)
                        map_ax.add_patch(plt.Circle((0,0),radius,fill=False,color='black',linewidth=1))
                        map_ax.plot([-.08*radius,0,.08*radius],[radius,1.12*radius,radius],color='black',linewidth=1)
                        map_ax.scatter(xy[:,0],xy[:,1],s=3,color='black');map_ax.set_aspect('equal');map_ax.axis('off')
                        if si==len(series)-1:fig.colorbar(image,ax=ax,shrink=.65,label='µV')
                        ax.axis('off')
                    elif mode in ['ersp','itc']:
                        if len(series)>1:
                            map_ax=ax.inset_axes([0,si/len(series),1,.85/len(series)])
                            map_ax.set_title(name,fontsize=8)
                        else:map_ax=ax
                        times=grids[key];low,high=(-3,3) if mode=='ersp' else ((-1,1) if condition=='B − A' else (0,1))
                        if options.get('color_limit'):low,high=(-options['color_limit'],options['color_limit'])
                        image=map_ax.imshow(mean,origin='lower',aspect='auto',extent=[times[0],times[-1],tf['freqs_hz'][0],tf['freqs_hz'][-1]],cmap=options.get('colormap','RdBu_r'),vmin=low,vmax=high)
                        map_ax.set_xlabel('Time (ms)');map_ax.set_ylabel('Hz')
                        if si==len(series)-1:fig.colorbar(image,ax=ax,shrink=.65,label='dB' if mode=='ersp' else 'ITC')
                        if len(series)>1:ax.axis('off')
                    else:
                        times=np.asarray(grids[key]);ax.plot(times,mean,label=name,color=color,lw=options.get('line_width',1.5))
                        band=options.get('error','SEM')
                        if band!='None':
                            spread=sem*(stats.t.ppf(.975,len(values)-1) if band=='95% CI' and len(values)>1 else 1)
                            ax.fill_between(times,mean-spread,mean+spread,color=color,alpha=.15,linewidth=0)
                        ax.axhline(.5 if mode=='ml' else 0,color='.6',lw=.5);ax.axvline(0,color='.6',lw=.5)
                        ax.set_xlabel('Time (ms)');ax.set_ylabel('AUC' if mode=='ml' else 'µV')
                        if options.get('negative_up',True) and mode!='ml':ax.yaxis.set_inverted(True)
                        if options.get('x_min') is not None:ax.set_xlim(options['x_min'],options.get('x_max'))
                        if options.get('y_min') is not None:ax.set_ylim(options['y_min'],options.get('y_max'))
                        ax.legend(frameon=False,fontsize=8)
                        for index,time in enumerate(times):export_rows.append([row,facet,serie,condition,time,mean[index],sem[index],len(values)])
                    found=True
                title=' · '.join(v for v in [label(row_factor,row) if row!='All' else '',label(facet_factor,facet) if facet!='All' else '',label('Condition',condition)] if v)
                ax.set_title(title,fontsize=options.get('font_size',10))
                if not found:ax.text(.5,.5,'No data',ha='center',va='center',transform=ax.transAxes)
                if mode not in ['topo','ersp','itc']:
                    ax.spines[['right','top']].set_visible(False)
    stem=output/f'GrandAverage_{mode}'
    paths=[]
    for suffix in ['png','svg','pdf']:
        path=stem.with_suffix('.'+suffix);fig.savefig(path,dpi=options.get('dpi',300),facecolor='white');paths.append(str(path))
    plt.close(fig)
    if export_rows:
        with stem.with_suffix('.csv').open('w',newline='',encoding='utf-8') as stream:
            writer=csv.writer(stream);writer.writerow(['row','facet','series','condition','time_ms','mean','sem','n_participants']);writer.writerows(export_rows)
    manifest=dict(options=options,n_matched_files=len(records),warnings=list(dict.fromkeys(warnings)),method='Equal participant weighting; within-participant/cell records averaged first. 95% CI is a pointwise t interval across participants; n=1 has no between-participant error estimate. No significance inferred from visual separation. TF maps are recomputed from epochs; ITC is mean participant ITC, not pooled trial phase locking.')
    stem.with_suffix('.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    return dict(paths=paths,warnings=manifest['warnings'],n_matched_files=len(records))


if __name__=='__main__':
    signal.signal(signal.SIGTERM,stop_engine)
    try:
        options=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
        result=render(options)
        Path(sys.argv[2]).write_text(json.dumps(result,allow_nan=False),encoding='utf-8')
    except Exception as error:
        print(str(error),file=sys.stderr);sys.exit(1)
