"""N-way ERP OLS / random-intercept MixedLM with fitted-design contrasts.

Participant-cell means are inference units. Marginal means equally weight other
factor levels; simple effects fix every other factor. All reported contrasts
for one metric share one multiple-testing family. Original factor codes remain
unchanged; display aliases are handled by the plotting layer.
"""
import itertools
import json
import sys
import warnings
import numpy as np
import pandas as pd
from patsy import build_design_matrices
from scipy import stats
import statsmodels.formula.api as smf
from statsmodels.stats.multitest import multipletests


def analyse(payload):
    if payload.get('posthocMethod', 'fdr') not in ['fdr','bonferroni']:
        raise ValueError('N-factor fitted contrasts support FDR or Bonferroni; choose one of these corrections.')
    df = pd.DataFrame(payload['rows'], columns=payload['headers'])
    factors = payload['factors']
    subject = payload.get('subjectCol')
    excluded = payload.get('excludedLevels', {})
    for factor in factors:
        df = df[~df[factor].isin(excluded.get(factor, [])) & df[factor].ne('')]
    names = {factor: f'F{i}' for i, factor in enumerate(factors)}
    results = []
    for metric in payload['metrics']:
        data = df.copy()
        data['Y'] = pd.to_numeric(data[metric], errors='coerce')
        data = data[np.isfinite(data['Y'])].rename(columns=names)
        data['SID'] = data[subject].astype(str) if subject else [f'row{i}' for i in range(len(data))]
        if data['SID'].eq('').any():
            raise ValueError('Participant IDs are missing; assign IDs before modelling.')
        columns = list(names.values())
        data = data.groupby(['SID'] + columns, observed=True, as_index=False)['Y'].mean()
        if len(data) < 3:
            continue
        levels = {f: sorted(data[names[f]].unique()) for f in factors}
        if any(len(v) < 2 for v in levels.values()):
            raise ValueError('Every model factor must have at least two included levels. Remove constant factors (including Condition for a single ERP difference).')
        terms = (' * ' if payload.get('includeInteractions', True) else ' + ').join(f'C({c})' for c in columns)
        formula = f'Y ~ {terms}'
        repeated = data.duplicated('SID').any()
        preferred = payload.get('preferredModel', 'auto')
        mixed = preferred == 'lmm' or (preferred == 'auto' and repeated)
        if mixed and not repeated:
            raise ValueError('LMM requires repeated observations within participants. Choose GLM for independent participant values.')
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter('always')
            if mixed:
                model = smf.mixedlm(formula, data, groups=data['SID'])
            else:
                model = smf.ols(formula, data)
            if np.linalg.matrix_rank(model.exog) < model.exog.shape[1] or len(data) <= model.exog.shape[1]:
                raise ValueError('Model design is rank deficient or saturated; reduce confounded factors or add independent participants.')
            fit = model.fit(reml=True, method=['lbfgs', 'powell'], maxiter=300, disp=False) if mixed else (
                model.fit(cov_type='cluster', cov_kwds={'groups': data['SID']}) if repeated else model.fit())
            if mixed and not fit.converged:
                raise ValueError('MixedLM did not converge. No significance is reported; review model balance, factor structure and participant counts.')
            effects = []
            table = fit.wald_test_terms(scalar=True).table
            for term, row in table.iterrows():
                if term == 'Intercept':
                    continue
                label = term
                for raw, safe in names.items():
                    label = label.replace(f'C({safe})', raw)
                effects.append(dict(term=label, f_stat=float(row['statistic']), p_value=float(row['pvalue']),
                                    p_perm=None, df_num=float(row['df_constraint']),
                                    df_denom=float(row['df_denom']) if 'df_denom' in row else None, eta_sq=None))
        coefficients = np.asarray(fit.fe_params if mixed else fit.params)
        covariance = np.asarray(fit.cov_params())[:len(coefficients), :len(coefficients)]
        if not np.isfinite(covariance).all() or np.linalg.eigvalsh((covariance+covariance.T)/2).min() < -1e-9:
            raise ValueError('The fitted fixed-effect covariance is invalid; no contrasts are reported. Review model identifiability.')
        design = fit.model.data.design_info

        def reference(factor, level, stratum):
            other = [f for f in factors if f != factor]
            combinations = itertools.product(*( [stratum[f]] if f in stratum else levels[f] for f in other))
            grid = pd.DataFrame([{names[factor]: level, **{names[f]: v for f, v in zip(other, values)}} for values in combinations])
            return np.asarray(build_design_matrices([design], grid)[0]).mean(axis=0)

        contrasts = []
        for factor in factors:
            other = [f for f in factors if f != factor]
            strata = [{}]
            if other:
                strata += [dict(zip(other, values)) for values in itertools.product(*(levels[f] for f in other))]
            for stratum in strata:
                for first, second in itertools.combinations(levels[factor], 2):
                    available = data
                    for f, level in stratum.items():
                        available = available[available[names[f]] == level]
                    if any(available[available[names[factor]] == level]['SID'].nunique() < 2 for level in [first, second]):
                        continue
                    vector = reference(factor, second, stratum) - reference(factor, first, stratum)
                    estimate = float(vector @ coefficients)
                    variance = float(vector @ covariance @ vector)
                    if variance <= 0 or not np.isfinite(variance):
                        continue
                    se = np.sqrt(variance)
                    statistic = estimate / se
                    use_normal = mixed or repeated
                    p = 2 * (stats.norm.sf(abs(statistic)) if use_normal else stats.t.sf(abs(statistic), fit.df_resid))
                    contrasts.append(dict(factor=factor, group_a=first, group_b=second, stratum=stratum,
                        contrast_scope='simple effect' if stratum else 'marginal', test='fitted-model Wald contrast',
                        mean_diff=estimate, standard_error=float(se), t_stat=float(statistic),
                        df=None if use_normal else float(fit.df_resid), p_raw=float(p)))
        if contrasts:
            method = 'bonferroni' if payload.get('posthocMethod') == 'bonferroni' else 'fdr_bh'
            adjusted = multipletests([c['p_raw'] for c in contrasts], method=method)[1]
            for contrast, p in zip(contrasts, adjusted):
                contrast.update(p_adj=float(p), significant=bool(p < .05))
        cells = {}
        for cell, block in data.groupby(columns, observed=True):
            if len(columns) == 1 and not isinstance(cell, tuple):
                cell = (cell,)
            key = '|'.join(f'{f}={v}' for f, v in zip(factors, cell))
            cells[key] = {'values': block['Y'].tolist(), 'subjects': block['SID'].tolist()}
        results.append(dict(metric=metric, backend='statsmodels', formula=formula,
            inference_note='Random intercept only. MixedLM and cluster-covariance contrasts use asymptotic normal/Wald tests; no Satterthwaite degrees of freedom.',
            model_type='Random-intercept MixedLM (REML)' if mixed else ('OLS GLM with participant-cluster covariance' if repeated else 'OLS GLM'),
            test_statistic='Wald χ²' if mixed or repeated else 'F', factors=factors, factor_levels=levels,
            model_effects=effects, posthoc=contrasts, cell_descriptives=cells, n_obs=len(data),
            n_subjects=data['SID'].nunique(), warnings=list(dict.fromkeys(str(w.message) for w in caught)),
            posthoc_family='All marginal and simple-effect contrasts within this metric',
            mean_difference_direction='group_b minus group_a'))
    return {'results': results, 'factors': factors}


if __name__ == '__main__':
    try:
        with open(sys.argv[1], encoding='utf-8') as stream:
            output = analyse(json.load(stream))
        with open(sys.argv[2], 'w', encoding='utf-8') as stream:
            json.dump(output, stream, allow_nan=False)
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
