#!/usr/bin/env python3
"""Group-level statistical analysis engine for CCS EEG Studio.

Implements state-of-the-art statistical modeling:
- Linear Mixed-Effects Models (LMM) with random intercepts for repeated-measures / multi-channel data
- General Linear Models (GLM / OLS / ANOVA) for between-subject macroarchitecture data
- Automated post-hoc pairwise contrasts with FDR / Tukey HSD / Bonferroni adjustments
- Publication-grade figures with annotated post-hoc significance markers
- Datastamped results folder containing journal-friendly CSVs, plots, and publishing-ready DOCX and PDF scientific reports
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any

# Adapted from CCS_SleepStudio/backend/group_stats.py. EEG epoch rows are
# aggregated before modeling, and metadata joins are validated as many-to-one.
import tempfile
os.environ.setdefault("MPLCONFIGDIR", str(Path(tempfile.gettempdir()) / "ccs-eeg-mpl"))
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec
import matplotlib.cm as cm
from matplotlib.colors import Normalize
import matplotlib.patheffects as path_effects
import numpy as np
import pandas as pd
from scipy import stats
import scipy.interpolate

try:
    from PIL import Image as PILImage
except ImportError:
    PILImage = None

try:
    import statsmodels.api as sm
    import statsmodels.formula.api as smf
    from statsmodels.stats.multitest import multipletests
    from statsmodels.stats.multicomp import pairwise_tukeyhsd
except ImportError:
    sm = None
    smf = None
    multipletests = None
    pairwise_tukeyhsd = None

try:
    import docx
    from docx.shared import Inches, Pt, RGBColor
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
    from docx.oxml import parse_xml, OxmlElement
    from docx.oxml.ns import nsdecls, qn
except ImportError:
    docx = None

try:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import inch
    from reportlab.platypus import (
        SimpleDocTemplate,
        Paragraph,
        Spacer,
        Table,
        TableStyle,
        Image as RLImage,
        KeepTogether,
        HRFlowable,
    )
except ImportError:
    SimpleDocTemplate = None


# ─── SIGNIFICANCE HELPERS ───────────────────────────────────────────────────

def p_to_star(p: float) -> str:
    if math.isnan(p):
        return "n/a"
    if p < 0.0001:
        return "****"
    if p < 0.001:
        return "***"
    if p < 0.01:
        return "**"
    if p < 0.05:
        return "*"
    return "ns"


def format_p_value(p: float) -> str:
    if math.isnan(p):
        return "n/a"
    if p < 0.0001:
        return "< 0.0001"
    if p < 0.001:
        return f"{p:.4f}"
    return f"{p:.3f}"


def calc_cohen_d(x: np.ndarray, y: np.ndarray) -> float:
    nx, ny = len(x), len(y)
    dof = nx + ny - 2
    if dof <= 0:
        return 0.0
    vx = np.var(x, ddof=1) if nx > 1 else 0.0
    vy = np.var(y, ddof=1) if ny > 1 else 0.0
    pooled_std = math.sqrt(((nx - 1) * vx + (ny - 1) * vy) / dof)
    if pooled_std == 0:
        return 0.0
    return float((np.mean(x) - np.mean(y)) / pooled_std)


# ─── DATA INSPECTION & PREPROCESSING ────────────────────────────────────────

SUBJECT_CANDIDATE_NAMES = [
    "subject identifier", "subject_code", "subject code", "subjname", "subject_name",
    "subject", "subjid", "subject id", "napid", "nap_id", "mappingcode", "sl.no.",
    "participant_id", "participant", "patient_id", "patient", "subj"
]

GROUP_CANDIDATE_NAMES = [
    "group", "groupid", "group_id", "status", "psgtype", "task", "condn", "condition",
    "cohort", "arm", "treatment", "diagnosis", "dx", "slept_well"
]

SUBGROUP_CANDIDATE_NAMES = [
    "roi", "region", "epoch_condition", "state", "session", "sessn",
    "chan", "channel", "electrode", "derivation", "eeg channel", "ageid", "age_id",
    "session", "session_id", "visit", "time_point", "timepoint", "epoch"
]

COVARIATE_CANDIDATE_NAMES = [
    "age", "gender", "sex", "education", "practiceyears", "bmi", "trt", "date_of_birth"
]

# Standard 10-20 and 10-10 scalp EEG derivations normalized to circle of radius 0.5 (Nose = +Y)
ELECTRODE_COORDS_2D: dict[str, tuple[float, float]] = {
    # Frontal Polar
    "FP1": (-0.15, 0.45), "FP2": (0.15, 0.45), "FPZ": (0.0, 0.47),
    # Anterior Frontal
    "AF3": (-0.18, 0.35), "AF4": (0.18, 0.35), "AF7": (-0.35, 0.35), "AF8": (0.35, 0.35), "AFZ": (0.0, 0.36),
    # Frontal
    "F3": (-0.22, 0.22), "F4": (0.22, 0.22), "FZ": (0.0, 0.24),
    "F1": (-0.11, 0.23), "F2": (0.11, 0.23),
    "F7": (-0.42, 0.22), "F8": (0.42, 0.22),
    # Fronto-Central
    "FC1": (-0.13, 0.11), "FC2": (0.13, 0.11), "FCZ": (0.0, 0.12),
    "FC3": (-0.26, 0.11), "FC4": (0.26, 0.11),
    "FC5": (-0.42, 0.11), "FC6": (0.42, 0.11),
    # Central
    "C3": (-0.24, 0.0), "C4": (0.24, 0.0), "CZ": (0.0, 0.0),
    "C1": (-0.12, 0.0), "C2": (0.12, 0.0),
    # Temporal
    "T3": (-0.45, 0.0), "T4": (0.45, 0.0),
    "T7": (-0.45, 0.0), "T8": (0.45, 0.0),
    "T5": (-0.38, -0.28), "T6": (0.38, -0.28),
    "P7": (-0.38, -0.28), "P8": (0.38, -0.28),
    "FT7": (-0.44, 0.12), "FT8": (0.44, 0.12),
    "TP7": (-0.44, -0.12), "TP8": (0.44, -0.12),
    # Centro-Parietal
    "CP1": (-0.13, -0.11), "CP2": (0.13, -0.11), "CPZ": (0.0, -0.12),
    "CP3": (-0.26, -0.11), "CP4": (0.26, -0.11),
    "CP5": (-0.42, -0.11), "CP6": (0.42, -0.11),
    # Parietal
    "P3": (-0.22, -0.22), "P4": (0.22, -0.22), "PZ": (0.0, -0.24),
    "P1": (-0.11, -0.23), "P2": (0.11, -0.23),
    # Parieto-Occipital
    "PO3": (-0.18, -0.35), "PO4": (0.18, -0.35), "PO7": (-0.35, -0.35), "PO8": (0.35, -0.35), "POZ": (0.0, -0.36),
    # Occipital
    "O1": (-0.15, -0.45), "O2": (0.15, -0.45), "OZ": (0.0, -0.47),
}


def normalize_channel_name(ch: str) -> str:
    """Normalizes channel name string for 10-20 mapping."""
    c = str(ch).upper().strip()
    c = re.sub(r"^EEG[\s\-_]?", "", c)
    c = re.sub(r"[\-_:](REF|AVG|LE|M1|M2|A1|A2)$", "", c)
    return c


def check_topoplot_suitability(channels: list[str]) -> tuple[bool, dict[str, tuple[float, float]]]:
    """Checks if recognized 10-20 EEG channels are of sufficient count and spatial distribution."""
    matched: dict[str, tuple[float, float]] = {}
    for ch in channels:
        norm = normalize_channel_name(ch)
        if norm in ELECTRODE_COORDS_2D:
            matched[ch] = ELECTRODE_COORDS_2D[norm]

    # Require at least 4 recognized scalp channels
    if len(matched) < 4:
        return False, {}

    xs = [coord[0] for coord in matched.values()]
    ys = [coord[1] for coord in matched.values()]
    # Must have both lateral (X) and anterior-posterior (Y) coverage
    if (max(xs) - min(xs) < 0.22) or (max(ys) - min(ys) < 0.22):
        return False, {}

    return True, matched


# Auxiliary and polygraphy non-EEG channel detection regex
NON_EEG_PATTERN = re.compile(
    r"^(POL|AUX|DC\d*|EOG|ECG|EKG|EMG|RESP|PPG|PULSE|SPO2|CO2|ETCO2|FLOW|THOR|ABDO|GSR|EDA|STATUS|TRIG|MARKER|EVENT)\b",
    re.IGNORECASE,
)


def is_non_eeg_channel(ch: str) -> bool:
    """Returns True if the channel name is recognized as auxiliary / non-EEG."""
    raw = str(ch).strip()
    upper = raw.upper()
    if NON_EEG_PATTERN.match(upper):
        return True
    if upper.startswith("POL ") or upper.startswith("POL_") or upper.startswith("POL$") or upper.startswith("POL:"):
        return True
    if "$" in upper:
        return True
    norm = normalize_channel_name(raw)
    if norm in (
        "A1", "A2", "M1", "M2", "REF", "E", "PG1", "PG2", "T1", "T2",
        "X1", "X2", "X3", "X4", "X5", "X6", "X7", "SPO2", "ETCO2", "PULSE", "CO2WAVE"
    ):
        return True
    if norm not in ELECTRODE_COORDS_2D:
        return True
    return False


def filter_eeg_channels(df: pd.DataFrame, include_non_eeg: bool = False) -> pd.DataFrame:
    """Removes non-EEG channels from the dataframe."""
    if include_non_eeg or "Chan" not in df.columns:
        return df
    mask = ~df["Chan"].apply(is_non_eeg_channel)
    filtered = df[mask].copy()
    if filtered.empty:
        return df
    return filtered


# 10-20 to Anatomical / Functional Region of Interest (ROI) mapping
CHANNEL_TO_ROI: dict[str, str] = {
    # Frontal
    "FP1": "Frontal", "FP2": "Frontal", "FPZ": "Frontal",
    "AF3": "Frontal", "AF4": "Frontal", "AF7": "Frontal", "AF8": "Frontal", "AFZ": "Frontal",
    "F7": "Frontal", "F5": "Frontal", "F3": "Frontal", "F1": "Frontal", "FZ": "Frontal", "F2": "Frontal", "F4": "Frontal", "F6": "Frontal", "F8": "Frontal",
    # Central
    "FC5": "Central", "FC3": "Central", "FC1": "Central", "FCZ": "Central", "FC2": "Central", "FC4": "Central", "FC6": "Central",
    "C5": "Central", "C3": "Central", "C1": "Central", "CZ": "Central", "C2": "Central", "C4": "Central", "C6": "Central",
    # Temporal
    "T3": "Temporal", "T4": "Temporal", "T7": "Temporal", "T8": "Temporal",
    "FT7": "Temporal", "FT8": "Temporal", "TP7": "Temporal", "TP8": "Temporal",
    "T5": "Temporal", "T6": "Temporal",
    # Parietal
    "CP5": "Parietal", "CP3": "Parietal", "CP1": "Parietal", "CPZ": "Parietal", "CP2": "Parietal", "CP4": "Parietal", "CP6": "Parietal",
    "P3": "Parietal", "P4": "Parietal", "PZ": "Parietal", "P1": "Parietal", "P2": "Parietal", "P5": "Parietal", "P6": "Parietal",
    "P7": "Temporal", "P8": "Temporal",
    # Occipital
    "PO7": "Occipital", "PO3": "Occipital", "POZ": "Occipital", "PO4": "Occipital", "PO8": "Occipital",
    "O1": "Occipital", "O2": "Occipital", "OZ": "Occipital", "IZ": "Occipital",
}


def recording_key(value):
    value = Path(str(value)).name.lower()
    value = re.sub(r"\.(features\.csv|ccseeg\.json|edf|set|fif|vhdr|mat|orb|signal|csv)$", "", value)
    return re.sub(r"(_clean|_preprocessed|_prepared|_cropped|_subepochs|_epoched)+$", "", value)


def prepare_eeg_table(df, metadata_path=None, metadata_key=None, include_non_eeg=False):
    df = df.copy()
    if "Chan" in df.columns and not include_non_eeg:
        df = filter_eeg_channels(df, include_non_eeg=include_non_eeg)

    if metadata_path:
        csv_metadata = str(metadata_path).lower().endswith('.csv')
        metadata_columns = pd.read_csv(metadata_path,nrows=0).columns if csv_metadata else pd.read_excel(metadata_path,nrows=0).columns
        join_column = metadata_key or metadata_columns[0]
        metadata = pd.read_csv(metadata_path,dtype={join_column:str}) if csv_metadata else pd.read_excel(metadata_path,dtype={join_column:str})
        key = metadata_key or metadata.columns[0]
        if key not in metadata.columns:
            raise ValueError(f"Metadata key {key!r} is not present")
        source_key = key if key in df.columns else "subjid" if key.lower() in ("subject", "subject_id", "subject code", "subj", "subjid") and "subjid" in df.columns else "Subj" if key.lower() in ("subject", "subject_id", "subject code", "subj") and "Subj" in df.columns else "filename" if "filename" in df.columns else "Subj" if "Subj" in df.columns else None
        if source_key is None:
            raise ValueError("No filename or subject key in feature CSV")
        df = df.copy(); metadata = metadata.copy()
        subject_join = source_key.lower() in ('subject','subject_id','subject code','subj','subjid','participant_id')
        def normalize_join(value):
            result=recording_key(value)
            return re.sub(r'^sub-', '', result) if subject_join else result
        df["__join_key"] = df[source_key].map(normalize_join)
        metadata["__join_key"] = metadata[key].map(normalize_join)
        if metadata["__join_key"].duplicated().any():
            raise ValueError("Metadata key is ambiguous: each recording/subject must match exactly one row")
        df = df.merge(metadata, on="__join_key", how="left", validate="many_to_one", indicator=True, suffixes=("", "_metadata"))
        if (df["_merge"] != "both").any():
            raise ValueError("Some feature recordings have no metadata match. Resolve missing matches before modeling.")
        df = df.drop(columns=["__join_key", "_merge"])
    if "filename" in df.columns and "Epoch" in df.columns:
        if "epoch_label" in df.columns:
            labels=df["epoch_label"].astype(str).str.replace(r"\s+/\s+[-+0-9.]+\s*s$","",regex=True).str.strip()
            valid=~labels.str.match(r"(?i)^(NA|nan|none|epoch\s*\d+|trial\s*\d+)$")
            if valid.any(): df["epoch_condition"]=labels.where(valid,"unlabeled")
        keys = ["filename"] + (["epoch_condition"] if "epoch_condition" in df.columns else []) + (["Chan"] if "Chan" in df.columns else [])
        ignored = {"Epoch", "Bin", "Start_s", "End_s", "EpochStart_s", "EpochEnd_s", "bin_idx", "bin_start_s", "bin_end_s", "epoch_label", "mode", "epoch_start_s", "epoch_end_s", "dfa_fei_window_s", "dfa_fei_context_start_s", "dfa_fei_context_end_s", "event_markers", "connectivity_settings"}
        metrics = [c for c in df.columns if c not in ignored and (
            c.lower().endswith(("_psd", "_fooof", "_irasa", "_nonlinear", "_dfa", "_fei", "_dfa_short", "_fei_short", "_erp")) or c.lower().startswith(("conn_", "graph_", "acw")))]
        if not metrics: raise ValueError("No EEG feature columns found")
        for column in metrics:
            converted = pd.to_numeric(df[column], errors="coerce")
            invalid = df[column].notna() & converted.isna() & df[column].astype(str).str.strip().ne("")
            if invalid.any():
                example = df.loc[invalid, column].astype(str).iloc[0]
                raise ValueError(f"Non-numeric feature value in {column}: {example!r}. Check CSV column alignment.")
            df[column] = converted.replace([np.inf, -np.inf], np.nan)
        masked_fei = 0
        lookup={c.lower():c for c in df}
        for column in metrics:
            lower=column.lower()
            if lower.endswith(('_fei','_fei_short')):
                partner=re.sub(r'_fei(_short)?$',r'_dfa\1',lower)
                if partner in lookup:
                    dfa=df[lookup[partner]].to_numpy(dtype=float,na_value=np.nan)
                    invalid=pd.Series(~np.isfinite(dfa) | (dfa <= .6),index=df.index)
                    masked_fei += int((invalid & df[column].notna()).sum())
                    df.loc[invalid,column]=np.nan
        aggregation = {c: "mean" if c in metrics else "first" for c in df.columns if c not in keys and c not in ignored}
        df = df.groupby(keys, dropna=False, sort=False).agg(aggregation).reset_index()
        df.attrs['excluded_unqualified_fei']=masked_fei
    return df


def apply_channel_scope(
    df: pd.DataFrame,
    scope: str = "roi",
    include_non_eeg: bool = False,
    include_channels: list[str] | None = None,
    exclude_channels: list[str] | None = None,
) -> pd.DataFrame:
    """Applies channel scoping, ROI aggregation, or global averaging."""
    if "Chan" not in df.columns:
        return df

    # Filter out non-EEG channels by default
    df = filter_eeg_channels(df, include_non_eeg=include_non_eeg)

    # Exclude user-specified channels
    if exclude_channels:
        ex_set = {normalize_channel_name(c) for c in exclude_channels}
        df = df[~df["Chan"].apply(lambda c: normalize_channel_name(c) in ex_set)].copy()

    # Include user-specified channels
    if include_channels:
        in_set = {normalize_channel_name(c) for c in include_channels}
        df = df[df["Chan"].apply(lambda c: normalize_channel_name(c) in in_set)].copy()

    scope_str = str(scope).lower().strip()
    id_key = "filename" if "filename" in df.columns else ("Subject" if "Subject" in df.columns else ("subjid" if "subjid" in df.columns else None))
    keys = ([id_key] if id_key else []) + (["epoch_condition"] if "epoch_condition" in df.columns else [])
    metrics = [
        c for c in df.columns
        if c.lower().endswith(("_psd", "_fooof", "_irasa", "_nonlinear", "_dfa", "_fei", "_dfa_short", "_fei_short", "_erp"))
        or c.lower().startswith(("conn_", "graph_", "acw"))
    ]

    # Mode A: Regional ROIs (Frontal, Central, Temporal, Parietal, Occipital)
    if scope_str in ("roi", "rois", "regions", "regional"):
        if not id_key:
            raise ValueError("ROI grouping requires a filename or Subject column")
        df["_norm_ch"] = df["Chan"].apply(normalize_channel_name)
        df["ROI"] = df["_norm_ch"].map(CHANNEL_TO_ROI)
        df = df.dropna(subset=["ROI"]).copy()

        agg = {c: "mean" if c in metrics else "first" for c in df.columns if c not in keys and c not in ("Chan", "_norm_ch", "ROI")}
        result = df.groupby(keys + ["ROI"], dropna=False, sort=False).agg(agg).reset_index()
        result["Chan"] = result["ROI"]
        result.attrs.update(df.attrs)
        return result

    # Mode B: Global Scalp Mean
    elif scope_str in ("mean", "global", "average"):
        if not id_key:
            raise ValueError("Channel averaging needs a recording filename or Subject column")
        agg = {c: "mean" if c in metrics else "first" for c in df.columns if c not in keys and c != "Chan"}
        result = df.groupby(keys, dropna=False, sort=False).agg(agg).reset_index()
        result["Chan"] = "Global Mean"
        result.attrs.update(df.attrs)
        return result

    # Mode C: Specific single channel or comma-separated channels
    elif scope_str not in ("all", "*"):
        targets = [normalize_channel_name(x.strip()) for x in scope_str.split(",") if x.strip()]
        selected = df[df["Chan"].apply(lambda c: normalize_channel_name(c) in targets)].copy()
        if selected.empty:
            raise ValueError(f"Channel {scope!r} is not present in scalp EEG derivations")
        return selected

    # Mode D: "all" genuine EEG channels
    return df


def detect_columns(df: pd.DataFrame) -> dict[str, Any]:
    cols = list(df.columns)
    # Strip optional "Metadata: " prefix and lowercase
    cols_clean = {c: re.sub(r"^metadata:\s*", "", c.lower().strip()) for c in cols}

    # Subject ID
    subject_id = None
    for cand in SUBJECT_CANDIDATE_NAMES:
        for c, cl in cols_clean.items():
            if cl == cand:
                subject_id = c
                break
        if subject_id:
            break
    if not subject_id:
        for c, cl in cols_clean.items():
            if "subject" in cl:
                subject_id = c
                break

    # Categorical columns
    categorical_cols = []
    for c in cols:
        cl = cols_clean[c]
        if cl in ("source_file", "source_path", "recording date"):
            continue
        # Check if numeric
        s_num = pd.to_numeric(df[c], errors="coerce")
        is_predominantly_numeric = s_num.notna().sum() >= max(3, len(df) * 0.70)
        is_known_factor_or_id = any(
            cand == cl for cand in (SUBJECT_CANDIDATE_NAMES + GROUP_CANDIDATE_NAMES + SUBGROUP_CANDIDATE_NAMES)
        )
        nunique = df[c].nunique(dropna=True)

        if not is_predominantly_numeric or is_known_factor_or_id:
            if df[c].dtype == "object" or (1 < nunique <= 12 and nunique < len(df) * 0.5):
                categorical_cols.append(c)

    # Require actual varying factors; recording IDs and constant task labels are not group contrasts.
    factors=[c for c in categorical_cols if c not in (subject_id,"filename","source_file","source_path") and df[c].nunique(dropna=True)>=2]
    # Primary group
    group_col = None
    for cand in GROUP_CANDIDATE_NAMES:
        for c in factors:
            if cols_clean[c] == cand:
                group_col = c
                break
        if group_col:
            break
    if not group_col:
        group_col=next((c for c in factors if cols_clean[c] in ("epoch_condition","state")),factors[0] if factors else None)

    # Subgroup / Factor 2
    subgroup_col = None
    for cand in SUBGROUP_CANDIDATE_NAMES:
        for c in factors:
            if c != group_col and cols_clean[c] == cand:
                subgroup_col = c
                break
        if subgroup_col:
            break

    # Covariates
    covariates = []
    for c in cols:
        cl = cols_clean[c]
        if cl in ("source_file", "source_path") or c in (group_col, subgroup_col, subject_id):
            continue
        if any(cand == cl for cand in COVARIATE_CANDIDATE_NAMES):
            covariates.append(c)

    # Numeric metric columns
    metric_cols = []
    for c in cols:
        if cols_clean[c] in SUBJECT_CANDIDATE_NAMES: continue
        if c in (subject_id, group_col, subgroup_col, "source_file", "source_path", "filename", "Chan", "Epoch", "Bin", "Start_s", "End_s", "subjid", "sessn", "condn", "bin_idx", "bin_start_s", "bin_end_s", "epoch_start_s", "epoch_end_s", "dfa_fei_window_s", "dfa_fei_context_start_s", "dfa_fei_context_end_s", "event_markers", "connectivity_settings"):
            continue
        if c in covariates:
            continue
        s = pd.to_numeric(df[c], errors="coerce")
        if s.notna().sum() >= 3 and s.nunique() >= 2:
            metric_cols.append(c)

    return {
        "subject_id": subject_id,
        "group_col": group_col,
        "subgroup_col": subgroup_col,
        "categorical_columns": categorical_cols,
        "covariates": covariates,
        "metric_columns": metric_cols,
        "total_rows": len(df),
        "total_columns": len(cols),
        "unique_subjects": int(df[subject_id].nunique(dropna=True)) if subject_id else len(df),
        "excluded_unqualified_fei": int(df.attrs.get('excluded_unqualified_fei',0)),
        "recording_count": int(df['filename'].nunique()) if 'filename' in df else len(df),
        "channel_count": int(df['Chan'].nunique()) if 'Chan' in df else 0,
    }


def is_macroarchitecture_or_channel_invariant(
    metric: str,
    df: pd.DataFrame,
    subject_id: str | None,
    subgroup_col: str | None,
) -> bool:
    """Determines whether a sleep metric represents global macroarchitecture that is redundant across channels."""
    ml = metric.lower().strip()
    macro_keywords = [
        "sleep_efficiency", "sleepefficiency", "tst", "trt", "waso", "sol", "spt",
        "sleep_maintenance_efficiency", "sleep_latency", "rem_latency", "w_onset",
        "w_duration", "n1_duration", "n2_duration", "n3_duration", "r_duration", "rem_duration",
        "nrem_duration", "n1_percentage", "n2_percentage", "n3_percentage", "r_percentage", "rem_percentage",
        "wake_percentage", "wake_duration", "stage_transitions", "stage_arousals", "shortawakenings"
    ]
    if any(k == ml or ml.startswith(k + "_") or ml.endswith("_" + k) for k in macro_keywords):
        return True
    if any(k in ml for k in ["sleep_efficiency", "sleepefficiency", "tst", "trt", "waso", "sol", "spt"]):
        return True

    # Empirical invariance check across subgroup (channels)
    if subject_id and subject_id in df.columns and subgroup_col and subgroup_col in df.columns:
        sub = df[[subject_id, subgroup_col, metric]].dropna()
        if len(sub) > 0:
            grouped = sub.groupby(subject_id)[metric].nunique()
            if (grouped <= 1).mean() > 0.90:
                return True

    return False


def categorize_metrics(metrics: list[str]) -> dict[str, list[str]]:
    categories: dict[str, list[str]] = {
        "Macroarchitecture": [],
        "Spindles": [],
        "Slow Waves": [],
        "Spectral Power": [],
        "Aperiodic & Complexity": [],
        "CAP (Cyclic Alternating Pattern)": [],
        "Sleep Cycles": [],
        "Other Regional": [],
    }

    for m in metrics:
        ml = m.lower()
        if ml.endswith("_erp"):
            categories.setdefault("ERP component measurements",[]).append(m)
            continue
        if ml.endswith(('_dfa_short','_fei_short')):
            categories.setdefault('Exploratory short-scale DFA / fE:I',[]).append(m)
            continue
        if ml.endswith(('_dfa','_fei')):
            categories.setdefault('Amplitude-envelope DFA / fE:I',[]).append(m)
            continue
        if "cap_" in ml or ml.startswith("cap") or "cyclic" in ml:
            categories["CAP (Cyclic Alternating Pattern)"].append(m)
        elif "cyc" in ml or "cycle" in ml or re.match(r"^c[1-5]_.*cycle", ml):
            categories["Sleep Cycles"].append(m)
        elif "sp_" in ml or "spindle" in ml:
            categories["Spindles"].append(m)
        elif "sw_" in ml or "slow" in ml:
            categories["Slow Waves"].append(m)
        elif any(k in ml for k in ["psd", "relpower", "abspower", "delta", "theta", "alpha", "sigma", "beta", "gamma"]) and "fooof" not in ml and "irasa" not in ml:
            categories["Spectral Power"].append(m)
        elif any(k in ml for k in ["fooof", "irasa", "exponent", "offset", "knee", "lzc", "dfa", "entropy", "nonlinear", "acw"]):
            categories["Aperiodic & Complexity"].append(m)
        elif any(k in ml for k in ["trt", "tst", "spt", "waso", "sol", "efficiency", "percentage", "onset", "latency", "duration", "streak", "transition", "arousal", "awakening", "slept_well"]):
            categories["Macroarchitecture"].append(m)
        else:
            categories["Other Regional"].append(m)

    return {k: v for k, v in categories.items() if v}


# ─── STATISTICAL MODELLING: LMM & GLM ──────────────────────────────────────

def clean_var_name(name: str) -> str:
    """Replaces non-alphanumeric chars for Patsy/statsmodels formulas."""
    clean = re.sub(r"[^\w]", "_", name.strip())
    if clean[0].isdigit():
        clean = "v_" + clean
    return clean


def clean_term_label(term: str, group_col: str, subgroup_col: str | None) -> str:
    """Translates Patsy dummy formula syntax into clear scientific terminology."""
    t = str(term).strip()
    if t.lower() == "intercept":
        return "Intercept"
    is_roi = (subgroup_col is not None and subgroup_col.upper() in ("ROI", "SUBGROUP"))
    sub_label = "ROI" if is_roi else (subgroup_col or "Region")
    t = re.sub(r"C\(GRP_VAR\)", "Group", t)
    t = re.sub(r"C\(SUBGRP_VAR\)", sub_label, t)
    t = re.sub(r"C\(" + re.escape(group_col) + r"\)", "Group", t)
    if subgroup_col:
        t = re.sub(r"C\(" + re.escape(subgroup_col) + r"\)", sub_label, t)
    t = re.sub(r"C\(SUBGroup\)", "ROI", t)
    t = re.sub(r"C\(Subgroup\)", "ROI", t)
    t = t.replace(":", " × ")
    if t == "Group":
        return f"Group ({group_col})"
    if t in ("ROI", "Region", "Subgroup", "SUBGroup", subgroup_col):
        return "ROI (Brain Region)" if is_roi else f"{subgroup_col or 'Region'} (Subgroup)"
    if "Group ×" in t or "× Group" in t:
        if is_roi or "ROI" in t or "SUBGroup" in t or "Subgroup" in t:
            return "Group × ROI (Interaction)"
        return f"{t} (Interaction)"
    return t


def fit_statistical_model(
    df: pd.DataFrame,
    metric: str,
    group_col: str,
    subgroup_col: str | None,
    covariates: list[str],
    subject_id: str | None,
    preferred_model: str = "auto",  # 'auto', 'lmm', 'glm'
    posthoc_method: str = "fdr",     # 'tukey', 'fdr', 'bonferroni'
) -> dict[str, Any] | None:
    """Fits LMM or GLM to the metric and calculates post-hoc contrasts."""
    is_macro = is_macroarchitecture_or_channel_invariant(metric, df, subject_id, subgroup_col)
    effective_subgroup_col = None if is_macro else subgroup_col

    needed_cols = []
    for c in [metric, group_col, effective_subgroup_col, subject_id] + [cv for cv in covariates if cv != metric]:
        if c and c in df.columns and c not in needed_cols:
            needed_cols.append(c)

    if metric.lower().startswith(("conn_mic_","conn_mim_","conn_gc_")) and "filename" in df.columns and "filename" not in needed_cols:
        needed_cols.append("filename")
        if "epoch_condition" in df.columns and "epoch_condition" not in needed_cols: needed_cols.append("epoch_condition")
    sub_df = df[needed_cols].copy()
    sub_df[metric] = pd.to_numeric(sub_df[metric], errors="coerce")
    for cov in covariates:
        if cov != metric and cov in sub_df.columns:
            numeric = pd.to_numeric(sub_df[cov], errors="coerce")
            if numeric.notna().sum() >= sub_df[cov].notna().sum() * .9:
                sub_df[cov] = numeric
    sub_df = sub_df.dropna(subset=[metric, group_col]+([subject_id] if subject_id else [])+([effective_subgroup_col] if effective_subgroup_col else [])).copy()

    if metric.lower().startswith(("conn_mic_","conn_mim_","conn_gc_")) and "filename" in sub_df.columns:
        sub_df = sub_df.drop_duplicates(subset=["filename"]+(["epoch_condition"] if "epoch_condition" in sub_df.columns else []))
        if effective_subgroup_col == "Chan": effective_subgroup_col = None
    # For macroarchitecture metrics (invariant across channels), collapse to one observation per subject
    if is_macro and subject_id and subject_id in sub_df.columns:
        sub_df = sub_df.drop_duplicates(subset=[subject_id]).copy()

    # Drop groups with < 2 observations
    group_counts = sub_df[group_col].value_counts()
    valid_groups = group_counts[group_counts >= 2].index.tolist()
    if len(valid_groups) < 2:
        return None
    sub_df = sub_df[sub_df[group_col].isin(valid_groups)].copy()

    if len(sub_df) < 6:
        return None

    # Check repeated measures per subject
    has_repeated_measures = False
    if not is_macro and subject_id and subject_id in sub_df.columns:
        n_obs = len(sub_df)
        n_subj = sub_df[subject_id].nunique()
        if n_obs > n_subj * 1.1:
            has_repeated_measures = True

    if subject_id and subject_id in sub_df and sub_df[subject_id].nunique()<2:
        raise ValueError("Inference requires multiple independent subjects")
    if subject_id and subject_id in sub_df:
        subject_counts=sub_df.groupby(group_col)[subject_id].nunique()
        if (subject_counts<2).any(): raise ValueError("Each group/condition needs at least two independent subjects")

    # Determine model type (Macroarchitecture always uses GLM/ANOVA to avoid redundant channel effects)
    if is_macro:
        use_lmm = False
    elif preferred_model == "lmm":
        use_lmm = True
    elif preferred_model == "glm":
        use_lmm = False
    else:  # auto
        use_lmm = has_repeated_measures and (subject_id is not None)

    # Rename columns to safe patsy names
    rename_map = {metric: "DEP_VAR", group_col: "GRP_VAR"}
    if effective_subgroup_col and effective_subgroup_col in sub_df.columns:
        rename_map[effective_subgroup_col] = "SUBGRP_VAR"
    if subject_id and subject_id in sub_df.columns:
        rename_map[subject_id] = "SUBJ_ID"
    valid_covs = []
    for i, cov in enumerate(covariates):
        if cov in sub_df.columns and sub_df[cov].notna().sum() >= len(sub_df) * 0.8:
            safe_cov = f"COV_{i}"
            rename_map[cov] = safe_cov
            valid_covs.append(safe_cov)

    safe_df = sub_df.rename(columns=rename_map).copy()
    # CSV parsers may infer session/run codes as integers. Contrast grids use
    # string level labels, so fit categorical factors on the same representation.
    for factor in ['GRP_VAR', 'SUBGRP_VAR']:
        if factor in safe_df:
            safe_df[factor] = safe_df[factor].astype(str)
    # Drop rows missing valid covariates
    if valid_covs:
        safe_df = safe_df.dropna(subset=valid_covs)

    if len(safe_df) < 6:
        return None

    # Construct formula
    formula_parts = ["C(GRP_VAR)"]
    has_subgroup = "SUBGRP_VAR" in safe_df.columns and safe_df["SUBGRP_VAR"].nunique() > 1
    if has_subgroup:
        formula_parts.append("C(SUBGRP_VAR)")
        formula_parts.append("C(GRP_VAR):C(SUBGRP_VAR)")
    for cv in valid_covs:
        formula_parts.append(cv)

    formula = f"DEP_VAR ~ {' + '.join(formula_parts)}"

    model_type = "GLM / OLS"
    model_effects: list[dict[str, Any]] = []
    model_summary_text = ""
    fit_converged = True
    r_squared = None

    if use_lmm and smf is not None:
        try:
            lmm_model = smf.mixedlm(formula, safe_df, groups=safe_df["SUBJ_ID"])
            if lmm_model.exog.shape[0]<=lmm_model.exog.shape[1] or np.linalg.matrix_rank(lmm_model.exog)<lmm_model.exog.shape[1]: raise ValueError("Model design is rank deficient; check confounded factors and covariates")
            lmm_fit = lmm_model.fit(reml=True)
            model_type = "Linear Mixed Model (LMM)"
            fit_converged = bool(lmm_fit.converged)
            if not fit_converged:
                raise RuntimeError("Mixed model did not converge")
            model_summary_text = str(lmm_fit.summary())

            # Wald test terms (Omnibus ANOVA-style hypothesis tests)
            try:
                wald = lmm_fit.wald_test_terms()
                w_frame = wald.summary_frame()
                for term_idx, row in w_frame.iterrows():
                    chi2_val = row.get("chi2", [np.nan])
                    val = float(chi2_val[0][0]) if hasattr(chi2_val, "__getitem__") and hasattr(chi2_val[0], "__getitem__") else float(chi2_val)
                    p_val = float(row.get("P>chi2", np.nan))
                    df_val = int(row.get("df constraint", 1))
                    term_name = str(term_idx).replace("GRP_VAR", group_col).replace("SUBGRP_VAR", subgroup_col or "Subgroup")
                    for orig, safe in rename_map.items():
                        term_name = term_name.replace(safe, orig)
                    clean_name = clean_term_label(term_name, group_col, subgroup_col)
                    model_effects.append({
                        "term": clean_name,
                        "raw_term": term_name,
                        "statistic": val,
                        "stat_type": "Chi2",
                        "df": df_val,
                        "p_value": p_val,
                        "significance": p_to_star(p_val),
                        "is_omnibus": True,
                    })
            except Exception:
                pass

            # Only fallback to coefficients if Wald test terms was completely empty
            if not model_effects:
                for param_name, coef in lmm_fit.params.items():
                    if param_name in ("Group Var", "Intercept"):
                        continue
                    se = float(lmm_fit.bse.get(param_name, np.nan))
                    z = float(lmm_fit.tvalues.get(param_name, np.nan))
                    p = float(lmm_fit.pvalues.get(param_name, np.nan))
                    ci = lmm_fit.conf_int().loc[param_name]
                    ci_low, ci_high = float(ci[0]), float(ci[1])
                    t_name = param_name.replace("GRP_VAR", group_col).replace("SUBGRP_VAR", subgroup_col or "Subgroup")
                    for orig, safe in rename_map.items():
                        t_name = t_name.replace(safe, orig)
                    clean_name = clean_term_label(t_name, group_col, subgroup_col)
                    model_effects.append({
                        "term": clean_name,
                        "raw_term": t_name,
                        "estimate": float(coef),
                        "std_error": se,
                        "statistic": z,
                        "stat_type": "z",
                        "df": len(safe_df) - len(lmm_fit.params),
                        "p_value": p,
                        "ci_lower": ci_low,
                        "ci_upper": ci_high,
                        "significance": p_to_star(p),
                        "is_omnibus": False,
                    })
        except Exception as exc:
            raise RuntimeError(f"LMM fit failed for {metric}: {exc}. Review design and subject IDs; no independent-observation fallback was used.") from exc

    if not use_lmm and smf is not None:
        try:
            if has_repeated_measures:
                ols_fit = smf.ols(formula, safe_df).fit(cov_type="cluster", cov_kwds={"groups":safe_df["SUBJ_ID"]}, use_t=True)
            else:
                ols_fit = smf.ols(formula, safe_df).fit(cov_type="HC3", use_t=True)
            if ols_fit.model.exog.shape[0]<=ols_fit.model.exog.shape[1] or np.linalg.matrix_rank(ols_fit.model.exog)<ols_fit.model.exog.shape[1]: raise ValueError("Model design is rank deficient; check factors and covariates")
            model_type = "General Linear Model (GLM / ANOVA)"
            model_summary_text = str(ols_fit.summary())
            r_squared = float(ols_fit.rsquared)

            try:
                anova = sm.stats.anova_lm(ols_fit, typ=2)
                for term_idx, row in anova.iterrows():
                    if term_idx == "Residual":
                        continue
                    f_val = float(row.get("F", np.nan))
                    p_val = float(row.get("PR(>F)", np.nan))
                    df_val = int(row.get("df", 1))
                    ss_val = float(row.get("sum_sq", 0.0))
                    resid_ss = float(anova.loc["Residual", "sum_sq"]) if "Residual" in anova.index else 1.0
                    partial_eta = ss_val / (ss_val + resid_ss) if (ss_val + resid_ss) > 0 else 0.0

                    t_name = str(term_idx).replace("GRP_VAR", group_col).replace("SUBGRP_VAR", subgroup_col or "Subgroup")
                    for orig, safe in rename_map.items():
                        t_name = t_name.replace(safe, orig)
                    clean_name = clean_term_label(t_name, group_col, subgroup_col)
                    model_effects.append({
                        "term": clean_name,
                        "raw_term": t_name,
                        "statistic": f_val,
                        "stat_type": "F",
                        "df": df_val,
                        "df_resid": int(ols_fit.df_resid),
                        "p_value": p_val,
                        "effect_size": partial_eta,
                        "effect_size_type": "partial_eta_sq",
                        "significance": p_to_star(p_val),
                        "is_omnibus": True,
                    })
            except Exception:
                pass

            if not model_effects:
                for param_name, coef in ols_fit.params.items():
                    if param_name == "Intercept":
                        continue
                    se = float(ols_fit.bse.get(param_name, np.nan))
                    t = float(ols_fit.tvalues.get(param_name, np.nan))
                    p = float(ols_fit.pvalues.get(param_name, np.nan))
                    ci = ols_fit.conf_int().loc[param_name]
                    ci_low, ci_high = float(ci[0]), float(ci[1])
                    t_name = param_name.replace("GRP_VAR", group_col).replace("SUBGRP_VAR", subgroup_col or "Subgroup")
                    for orig, safe in rename_map.items():
                        t_name = t_name.replace(safe, orig)
                    clean_name = clean_term_label(t_name, group_col, subgroup_col)
                    model_effects.append({
                        "term": clean_name,
                        "raw_term": t_name,
                        "estimate": float(coef),
                        "std_error": se,
                        "statistic": t,
                        "stat_type": "t",
                        "df": int(ols_fit.df_resid),
                        "p_value": p,
                        "ci_lower": ci_low,
                        "ci_upper": ci_high,
                        "significance": p_to_star(p),
                        "is_omnibus": False,
                    })
        except Exception as e:
            return None

    # ── Descriptive Statistics ─────────────────────────────────────────────
    descriptive_stats: list[dict[str, Any]] = []
    group_levels = sorted([str(g) for g in sub_df[group_col].dropna().unique()])
    subgroup_levels = sorted([str(sg) for sg in sub_df[subgroup_col].dropna().unique()]) if has_subgroup else [None]

    for sg in subgroup_levels:
        for grp in group_levels:
            if sg is not None:
                mask = (sub_df[group_col].astype(str) == grp) & (sub_df[subgroup_col].astype(str) == sg)
            else:
                mask = sub_df[group_col].astype(str) == grp
            vals = sub_df.loc[mask, metric].dropna().values
            if len(vals) == 0:
                continue
            descriptive_stats.append({
                "group": grp,
                "subgroup": sg,
                "n": int(len(vals)),
                "mean": float(np.mean(vals)),
                "std": float(np.std(vals, ddof=1)) if len(vals) > 1 else 0.0,
                "median": float(np.median(vals)),
                "iqr": float(stats.iqr(vals)) if len(vals) > 1 else 0.0,
                "min": float(np.min(vals)),
                "max": float(np.max(vals)),
            })

    # Model-based estimated marginal means and Wald contrasts, retaining
    # covariate adjustment and the mixed/clustered covariance of the fitted model.
    from patsy import build_design_matrices
    posthoc_contrasts = []
    fitted = lmm_fit if use_lmm else ols_fit
    def design_row(group, subgroup=None):
        rows=safe_df[valid_covs].copy() if valid_covs else pd.DataFrame(index=[0])
        rows["GRP_VAR"]=group
        if has_subgroup: rows["SUBGRP_VAR"]=subgroup
        for cov in valid_covs:
            if pd.api.types.is_numeric_dtype(safe_df[cov]): rows[cov]=float(safe_df[cov].mean())
        return np.asarray(build_design_matrices([fitted.model.data.design_info],rows)[0]).mean(axis=0)
    def contrast(group1, group2, subgroup1=None, subgroup2=None, within=False):
        x1, x2 = design_row(group1,subgroup1), design_row(group2,subgroup2)
        coefficients = np.asarray(fitted.fe_params if use_lmm else fitted.params)
        test = fitted.t_test((x1-x2)[None,:])
        first = sub_df[sub_df[group_col].astype(str)==str(group1)]
        second = sub_df[sub_df[group_col].astype(str)==str(group2)]
        if has_subgroup:
            first = first[first[effective_subgroup_col].astype(str)==str(subgroup1)]
            second = second[second[effective_subgroup_col].astype(str)==str(subgroup2)]
        v1 = first.groupby(subject_id)[metric].mean().values if subject_id else first[metric].values
        v2 = second.groupby(subject_id)[metric].mean().values if subject_id else second[metric].values
        return {"contrast_type":"Subgroup within Group" if within else "Group within Subgroup" if has_subgroup else "Group",
            "factor":group_col if within else effective_subgroup_col if has_subgroup else group_col,
            "level":str(group1) if within else str(subgroup1) if has_subgroup else "all",
            "group1":str(subgroup1) if within else str(group1),"group2":str(subgroup2) if within else str(group2),
            "mean1":float(x1@coefficients),"mean2":float(x2@coefficients),"n1":len(v1),"n2":len(v2),
            "t_stat":float(np.asarray(test.tvalue).item()),"p_raw":float(np.asarray(test.pvalue).item()),
            "cohen_d":calc_cohen_d(v1,v2),"comparison":"model-adjusted marginal means"}
    for subgroup in subgroup_levels if has_subgroup else [None]:
        for i,first in enumerate(group_levels):
            for second in group_levels[i+1:]:
                posthoc_contrasts.append(contrast(first,second,subgroup,subgroup))
    if has_subgroup:
        for group in group_levels:
            for i,first in enumerate(subgroup_levels):
                for second in subgroup_levels[i+1:]:
                    posthoc_contrasts.append(contrast(group,group,first,second,True))

    # Adjust p-values
    if posthoc_contrasts and multipletests is not None:
        raw_ps = [c["p_raw"] for c in posthoc_contrasts]
        method_key = "fdr_bh" if posthoc_method in ("fdr", "tukey") else "bonferroni"
        _, adj_ps, _, _ = multipletests(raw_ps, method=method_key)
        for idx, adj_p in enumerate(adj_ps):
            posthoc_contrasts[idx]["p_adj"] = float(adj_p)
            posthoc_contrasts[idx]["significance"] = p_to_star(float(adj_p))
    else:
        for c in posthoc_contrasts:
            c["p_adj"] = c["p_raw"]
            c["significance"] = p_to_star(c["p_raw"])

    return {
        "metric": metric,
        "group_col": group_col,
        "subgroup_col": effective_subgroup_col if has_subgroup else None,
        "subject_id": subject_id,
        "is_macroarchitecture": is_macro,
        "covariates": valid_covs,
        "model_type": model_type,
        "formula": formula,
        "n_obs": len(safe_df),
        "n_subjects": safe_df["SUBJ_ID"].nunique() if "SUBJ_ID" in safe_df.columns else len(safe_df),
        "fit_converged": fit_converged,
        "r_squared": r_squared,
        "model_effects": model_effects,
        "descriptive_stats": descriptive_stats,
        "posthoc_contrasts": posthoc_contrasts,
        "data_sample": safe_df.to_dict(orient="records"),
    }


# ─── PUBLICATION PLOT GENERATION WITH SIGNIFICANCE BRACKETS ─────────────────

def generate_publication_plot(
    result: dict[str, Any],
    raw_df: pd.DataFrame,
    output_png_path: Path,
) -> Path:
    """Renders a publication-grade figure with box/jittered scatter and significance brackets."""
    metric = result["metric"]
    group_col = result["group_col"]
    subgroup_col = result["subgroup_col"]
    contrasts = result["posthoc_contrasts"]

    # Filter data
    needed = [metric, group_col]
    if subgroup_col:
        needed.append(subgroup_col)
    subjid = result.get("subject_id")
    if subjid and subjid in raw_df.columns and subjid not in needed:
        needed.append(subjid)

    clean = raw_df[needed].dropna().copy()
    clean[metric] = pd.to_numeric(clean[metric], errors="coerce")
    clean = clean.dropna(subset=[metric])

    if result.get("is_macroarchitecture") and subjid and subjid in clean.columns:
        clean = clean.drop_duplicates(subset=[subjid]).copy()

    groups = sorted([str(g) for g in clean[group_col].unique()])
    palette = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b"]
    color_map = {g: palette[i % len(palette)] for i, g in enumerate(groups)}

    has_subgroup = subgroup_col is not None and subgroup_col in clean.columns and clean[subgroup_col].nunique() > 1
    if has_subgroup:
        unique_sgs = list(clean[subgroup_col].unique())
        standard_roi_order = ["Frontal", "Central", "Temporal", "Parietal", "Occipital"]
        if any(str(s).capitalize() in standard_roi_order for s in unique_sgs):
            subgroups = sorted(
                [str(sg) for sg in unique_sgs],
                key=lambda x: standard_roi_order.index(x.capitalize()) if x.capitalize() in standard_roi_order else 99
            )
        else:
            subgroups = sorted([str(sg) for sg in unique_sgs])
    else:
        subgroups = [None]

    # Plot dimensions
    fig_width = max(6.5, 2.6 * len(subgroups) if has_subgroup else 2.0 * len(groups))
    fig, ax = plt.subplots(figsize=(fig_width, 5.0), dpi=300)

    # Style
    ax.set_facecolor("#fafafa")
    fig.patch.set_facecolor("white")
    ax.grid(axis="y", color="#e0e0e0", linestyle="--", linewidth=0.7, alpha=0.7)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color("#333333")
    ax.spines["bottom"].set_color("#333333")

    y_vals_all = clean[metric].values
    y_min = float(np.min(y_vals_all)) if len(y_vals_all) > 0 else 0.0
    y_max = float(np.max(y_vals_all)) if len(y_vals_all) > 0 else 1.0
    y_span = max(1e-5, y_max - y_min)

    positions = []
    box_data = []
    box_colors = []
    x_labels = []

    if not has_subgroup:
        # Single factor layout
        for i, grp in enumerate(groups):
            vals = clean[clean[group_col].astype(str) == grp][metric].values
            pos = i + 1
            positions.append(pos)
            box_data.append(vals)
            box_colors.append(color_map[grp])
            x_labels.append(grp)
            # Jittered scatter points
            jitter = np.random.normal(0, 0.05, size=len(vals))
            ax.scatter(pos + jitter, vals, color=color_map[grp], alpha=0.55, s=26, zorder=3, edgecolors="#333333", linewidths=0.35)

        bp = ax.boxplot(
            box_data, positions=positions, widths=0.45, patch_artist=True,
            showmeans=True, meanline=True, zorder=2,
            boxprops=dict(linewidth=1.2),
            whiskerprops=dict(linewidth=1.2, color="#444444"),
            capprops=dict(linewidth=1.2, color="#444444"),
            medianprops=dict(linewidth=1.8, color="#222222"),
            meanprops=dict(linewidth=1.5, color="#d95f02", linestyle=":"),
        )
        for patch, color in zip(bp["boxes"], box_colors):
            patch.set_facecolor(matplotlib.colors.to_rgba(color, alpha=0.35))
            patch.set_edgecolor(color)

        ax.set_xticks(positions)
        ax.set_xticklabels(x_labels, fontsize=11, fontweight="bold")

        # Significance brackets between groups
        bracket_y = y_max + y_span * 0.05
        step = y_span * 0.12
        for c in contrasts:
            if c.get("contrast_type") == "Main Group Effect":
                g1, g2 = c["group1"], c["group2"]
                if g1 in groups and g2 in groups:
                    idx1 = groups.index(g1) + 1
                    idx2 = groups.index(g2) + 1
                    sig = c.get("significance", "ns")
                    p_val = c.get("p_adj", c.get("p_raw", 1.0))
                    # Draw bracket
                    ax.plot([idx1, idx1, idx2, idx2], [bracket_y, bracket_y + step * 0.3, bracket_y + step * 0.3, bracket_y], color="#222222", lw=1.2)
                    label = f"{sig} (p={format_p_value(p_val)})" if sig != "ns" else "ns"
                    ax.text((idx1 + idx2) / 2.0, bracket_y + step * 0.35, label, ha="center", va="bottom", fontsize=9.5, fontweight="bold", color="#d95f02" if sig != "ns" else "#555555")
                    bracket_y += step

        ax.set_ylim(y_min - y_span * 0.08, bracket_y + step * 0.3)

    else:
        # Two factors: grouped by Subgroup (e.g. ROI) with hue for Group
        n_grps = len(groups)
        width = 0.8 / n_grps
        x_center = []
        bracket_y = y_max + y_span * 0.05
        step = y_span * 0.12
        max_y_bracket = bracket_y

        for s_idx, sg in enumerate(subgroups):
            sg_center = (s_idx + 1) * 1.5
            x_center.append(sg_center)
            sg_mask = clean[subgroup_col].astype(str) == sg

            for g_idx, grp in enumerate(groups):
                vals = clean[sg_mask & (clean[group_col].astype(str) == grp)][metric].values
                offset = (g_idx - (n_grps - 1) / 2.0) * width
                pos = sg_center + offset
                if len(vals) > 0:
                    bp = ax.boxplot(
                        [vals], positions=[pos], widths=width * 0.85, patch_artist=True,
                        showmeans=True, meanline=True, zorder=2,
                        boxprops=dict(linewidth=1.1),
                        whiskerprops=dict(linewidth=1.1, color="#444444"),
                        capprops=dict(linewidth=1.1, color="#444444"),
                        medianprops=dict(linewidth=1.6, color="#222222"),
                        meanprops=dict(linewidth=1.4, color="#d95f02", linestyle=":"),
                    )
                    bp["boxes"][0].set_facecolor(matplotlib.colors.to_rgba(color_map[grp], alpha=0.35))
                    bp["boxes"][0].set_edgecolor(color_map[grp])
                    jitter = np.random.normal(0, width * 0.08, size=len(vals))
                    ax.scatter(pos + jitter, vals, color=color_map[grp], alpha=0.55, s=24, zorder=3, edgecolors="#333333", linewidths=0.35)

            # Mini significance brackets within this subgroup
            sg_contrasts = [c for c in contrasts if c.get("factor") == subgroup_col and c.get("level") == sg]
            local_y = (np.max(clean[sg_mask][metric].values) if sg_mask.sum() > 0 else y_max) + y_span * 0.04
            for c in sg_contrasts:
                g1, g2 = c["group1"], c["group2"]
                if g1 in groups and g2 in groups:
                    idx1 = groups.index(g1)
                    idx2 = groups.index(g2)
                    pos1 = sg_center + (idx1 - (n_grps - 1) / 2.0) * width
                    pos2 = sg_center + (idx2 - (n_grps - 1) / 2.0) * width
                    sig = c.get("significance", "ns")
                    p_val = c.get("p_adj", c.get("p_raw", 1.0))
                    if sig != "ns":
                        ax.plot([pos1, pos1, pos2, pos2], [local_y, local_y + step * 0.25, local_y + step * 0.25, local_y], color="#d95f02", lw=1.1)
                        ax.text((pos1 + pos2) / 2.0, local_y + step * 0.3, f"{sig}", ha="center", va="bottom", fontsize=10, fontweight="bold", color="#d95f02")
                        local_y += step * 0.6
                        max_y_bracket = max(max_y_bracket, local_y)

        ax.set_ylim(y_min - y_span * 0.08, max_y_bracket + step * 0.35)
        ax.set_xticks(x_center)
        ax.set_xticklabels(subgroups, fontsize=11, fontweight="bold")
        ax.set_xlabel(subgroup_col, fontsize=11, fontweight="bold", labelpad=8)

        # Legend for groups
        legend_handles = [
            matplotlib.patches.Patch(facecolor=matplotlib.colors.to_rgba(color_map[g], alpha=0.5), edgecolor=color_map[g], label=g)
            for g in groups
        ]
        ax.legend(handles=legend_handles, title=group_col, loc="upper right", framealpha=0.9, fontsize=9.5)

    clean_metric_title = metric.replace("_", " ")
    ax.set_ylabel(clean_metric_title, fontsize=11, fontweight="bold", labelpad=8)
    model_type = result["model_type"]
    if result.get("is_macroarchitecture"):
        ax.set_title(
            f"{clean_metric_title} by {group_col}\n({model_type}, N={result['n_obs']}) — [Whole-Night Global Metric; Invariant across Channels]",
            fontsize=10.5,
            fontweight="bold",
            pad=12,
        )
    else:
        ax.set_title(
            f"{clean_metric_title} by {group_col}{f' across {subgroup_col}' if has_subgroup else ''}\n({model_type}, N={result['n_obs']})",
            fontsize=12,
            fontweight="bold",
            pad=12,
        )

    plt.tight_layout()
    output_png_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png_path, dpi=300)
    plt.close(fig)
    return output_png_path


# ─── ELECTRODE-ADJACENCY TFCE (eTFCE) ────────────────────────────────────────

def compute_etfce(
    raw_df: pd.DataFrame,
    metric: str,
    group_col: str,
    channel_col: str,
    subject_id: str | None = None,
    n_perm: int = 1000,
    e_param: float = 0.5,
    h_param: float = 2.0,
    dh_steps: int = 50,
) -> dict[str, Any] | None:
    """Computes electrode-adjacency Threshold-Free Cluster Enhancement (eTFCE) across all pairwise group contrasts.

    References:
    - Smith & Nichols (2009) NeuroImage: Threshold-free cluster enhancement.
    - Mensen et al. (2013) NeuroImage: Optimal parameters for electrode-adjacency TFCE in EEG.

    Algorithm:
    1. Constructs electrode adjacency graph from 10-20 spherical scalp coordinates.
    2. Calculates two-sample t-statistic for each electrode between each pair of groups.
    3. Integrates cluster extent across thresholds:
       TFCE(s) = sum_{h} (cluster_size(s, h))^E * h^H * dh
    4. Evaluates permutation distribution of max-TFCE by permuting subject group labels (n_perm iterations).
    5. Yields non-parametric FWER cluster-corrected p-values for all electrodes and contrasts.
    """
    needed = [metric, group_col, channel_col] + ([subject_id] if subject_id else [])
    clean = raw_df[needed].dropna().copy()
    clean[metric] = pd.to_numeric(clean[metric], errors="coerce")
    clean = clean.dropna(subset=[metric])
    groups = sorted([str(g) for g in clean[group_col].dropna().unique()])
    if len(groups) < 2:
        return None

    channels = sorted([str(c) for c in clean[channel_col].unique()])
    is_ok, matched = check_topoplot_suitability(channels)
    if not is_ok or len(matched) < 4:
        return None

    ch_list = list(matched.keys())
    n_ch = len(ch_list)
    adj: dict[int, list[int]] = {i: [] for i in range(n_ch)}
    for i in range(n_ch):
        x1, y1 = matched[ch_list[i]]
        for j in range(i + 1, n_ch):
            x2, y2 = matched[ch_list[j]]
            dist = math.hypot(x1 - x2, y1 - y2)
            if dist <= 0.26:
                adj[i].append(j)
                adj[j].append(i)

    # Average within subject if repeated measures exist
    if subject_id and subject_id in clean.columns:
        subj_df = clean.groupby([subject_id, group_col, channel_col])[metric].mean().reset_index()
    else:
        subj_df = clean

    def calc_t(m1: np.ndarray, m2: np.ndarray) -> np.ndarray:
        n1_sub, n2_sub = m1.shape[0], m2.shape[0]
        mean1, mean2 = np.mean(m1, axis=0), np.mean(m2, axis=0)
        var1 = np.var(m1, axis=0, ddof=1) if n1_sub > 1 else np.zeros(m1.shape[1])
        var2 = np.var(m2, axis=0, ddof=1) if n2_sub > 1 else np.zeros(m2.shape[1])
        denom = np.sqrt(var1 / n1_sub + var2 / n2_sub)
        denom[denom == 0] = 1e-10
        return (mean2 - mean1) / denom

    def tfce_score(t_vec: np.ndarray) -> np.ndarray:
        max_t = float(np.max(np.abs(t_vec)))
        if max_t <= 0:
            return np.zeros(n_ch)
        h_vals = np.linspace(0, max_t, dh_steps)
        dh = float(h_vals[1] - h_vals[0]) if len(h_vals) > 1 else 0.1
        scores = np.zeros(n_ch)

        for h in h_vals[1:]:
            visited_pos = set()
            for seed in range(n_ch):
                if seed not in visited_pos and t_vec[seed] >= h:
                    comp_nodes = []
                    q = [seed]
                    visited_pos.add(seed)
                    while q:
                        curr = q.pop(0)
                        comp_nodes.append(curr)
                        for nbr in adj[curr]:
                            if nbr not in visited_pos and t_vec[nbr] >= h:
                                visited_pos.add(nbr)
                                q.append(nbr)
                    c_size = len(comp_nodes)
                    inc = (c_size ** e_param) * (h ** h_param) * dh
                    for node in comp_nodes:
                        scores[node] += inc

            visited_neg = set()
            for seed in range(n_ch):
                if seed not in visited_neg and t_vec[seed] <= -h:
                    comp_nodes = []
                    q = [seed]
                    visited_neg.add(seed)
                    while q:
                        curr = q.pop(0)
                        comp_nodes.append(curr)
                        for nbr in adj[curr]:
                            if nbr not in visited_neg and t_vec[nbr] <= -h:
                                visited_neg.add(nbr)
                                q.append(nbr)
                    c_size = len(comp_nodes)
                    inc = (c_size ** e_param) * (h ** h_param) * dh
                    for node in comp_nodes:
                        scores[node] += inc

        return scores

    # Prepare group matrices
    group_mats: dict[str, np.ndarray] = {}
    for g in groups:
        s_g = subj_df[subj_df[group_col].astype(str) == g]
        subjs = sorted(s_g[subject_id].unique()) if (subject_id and subject_id in s_g.columns) else list(range(len(s_g)))
        if len(subjs) < 2:
            continue
        mat = np.full((len(subjs), n_ch), np.nan)
        for i, s in enumerate(subjs):
            sdf = s_g[s_g[subject_id] == s] if (subject_id and subject_id in s_g.columns) else s_g.iloc[[i]]
            for c_idx, ch in enumerate(ch_list):
                v = sdf[sdf[channel_col].astype(str) == ch][metric].values
                if len(v) > 0:
                    mat[i, c_idx] = v[0]
        for c_idx in range(n_ch):
            col = mat[:, c_idx]
            m = float(np.nanmean(col)) if np.any(~np.isnan(col)) else 0.0
            mat[np.isnan(col), c_idx] = m
        group_mats[g] = mat

    pairwise_results: dict[str, Any] = {}
    rng = np.random.default_rng(42)
    all_sig_channels: set[str] = set()

    for i in range(len(groups)):
        for j in range(i + 1, len(groups)):
            g1, g2 = groups[i], groups[j]
            if g1 not in group_mats or g2 not in group_mats:
                continue
            mat_g1 = group_mats[g1]
            mat_g2 = group_mats[g2]
            obs_t = calc_t(mat_g1, mat_g2)
            obs_tfce = tfce_score(obs_t)

            combined = np.vstack([mat_g1, mat_g2])
            n1_len = mat_g1.shape[0]
            n_tot = combined.shape[0]
            max_null = np.zeros(n_perm)

            for p in range(n_perm):
                perm_idx = rng.permutation(n_tot)
                perm_g1 = combined[perm_idx[:n1_len]]
                perm_g2 = combined[perm_idx[n1_len:]]
                perm_t = calc_t(perm_g1, perm_g2)
                perm_tfce = tfce_score(perm_t)
                max_null[p] = float(np.max(perm_tfce))

            p_etfce = np.array([
                float(np.sum(max_null >= obs_tfce[c]) + 1) / (n_perm + 1)
                for c in range(n_ch)
            ])
            dof = mat_g1.shape[0] + mat_g2.shape[0] - 2
            p_uncorr = 2 * (1 - stats.t.cdf(np.abs(obs_t), df=dof))
            sig_channels = [ch_list[c] for c in range(n_ch) if p_etfce[c] < 0.05]
            all_sig_channels.update(sig_channels)

            pair_key = f"{g2} - {g1}"
            pairwise_results[pair_key] = {
                "pair_key": pair_key,
                "group1": g1,
                "group2": g2,
                "channels": ch_list,
                "t_stats": [float(x) for x in obs_t],
                "tfce_scores": [float(x) for x in obs_tfce],
                "p_uncorrected": [float(x) for x in p_uncorr],
                "p_etfce": [float(x) for x in p_etfce],
                "min_p_etfce": float(np.min(p_etfce)),
                "sig_channels_etfce": sig_channels,
            }

    primary_pair = next(iter(pairwise_results.values())) if pairwise_results else {}
    return {
        "channels": ch_list,
        "groups": groups,
        "pairwise": pairwise_results,
        "sig_channels_etfce": sorted(list(all_sig_channels)),
        "n_perm": n_perm,
        "group1": str(groups[0]),
        "group2": str(groups[1]) if len(groups) > 1 else "",
        "t_stats": primary_pair.get("t_stats", []),
        "tfce_scores": primary_pair.get("tfce_scores", []),
        "p_uncorrected": primary_pair.get("p_uncorrected", []),
        "p_etfce": primary_pair.get("p_etfce", []),
        "min_p_etfce": min((p.get("min_p_etfce", 1.0) for p in pairwise_results.values()), default=1.0),
        "e_param": e_param,
        "h_param": h_param,
    }


# ─── 2D EEG TOPOGRAPHIC SCALP DISTRIBUTION (TOPOPLOT) ────────────────────────

def generate_topoplot(
    raw_df: pd.DataFrame,
    metric: str,
    group_col: str,
    channel_col: str,
    posthoc_contrasts: list[dict[str, Any]],
    output_png_path: Path,
    etfce_result: dict[str, Any] | None = None,
) -> Path | None:
    """Renders 2D EEG topographic scalp distribution map (Topoplot) across channels for each group and differences.

    Uses dedicated GridSpec colorbar axes to completely eliminate overlap:
      Row 1: Group Means for each cohort (standard EEG Spectral_r colormap, shared range [vmin, vmax]).
      Row 2: Pairwise Differences with robust eTFCE significance overlays (symmetric RdBu_r divergent colormap).
    """
    needed = [metric, group_col, channel_col]
    clean = raw_df[needed].dropna().copy()
    clean[metric] = pd.to_numeric(clean[metric], errors="coerce")
    clean = clean.dropna(subset=[metric])
    if len(clean) < 6:
        return None

    channels = sorted([str(c) for c in clean[channel_col].unique()])
    is_ok, matched = check_topoplot_suitability(channels)
    if not is_ok or len(matched) < 4:
        return None

    ch_list = list(matched.keys())
    clean = clean[clean[channel_col].astype(str).isin(ch_list)].copy()
    groups = sorted([str(g) for g in clean[group_col].unique()])
    if len(groups) < 1:
        return None

    # Calculate group means per channel
    group_means: dict[str, dict[str, float]] = {}
    for g in groups:
        g_df = clean[clean[group_col].astype(str) == g]
        means = g_df.groupby(channel_col)[metric].mean()
        group_means[g] = {ch: float(means.get(ch, np.nan)) for ch in ch_list}

    # High-resolution grid for spherical interpolation
    r = 0.5
    xi, yi = np.mgrid[-0.55:0.55:200j, -0.55:0.55:200j]
    mask = (xi**2 + yi**2) <= r**2
    pts = np.array([matched[ch] for ch in ch_list])

    # Global min and max across group means for shared colormap
    all_mean_vals = [v for g in groups for v in group_means[g].values() if not math.isnan(v)]
    if not all_mean_vals:
        return None
    g_min, g_max = min(all_mean_vals), max(all_mean_vals)
    if g_min == g_max:
        g_min -= 0.1
        g_max += 0.1

    def draw_head_outline(ax):
        circle = plt.Circle((0, 0), r, color="black", fill=False, linewidth=1.8, zorder=4)
        ax.add_patch(circle)
        # Nose
        ax.plot([-0.05, 0.0, 0.05], [0.49, 0.54, 0.49], color="black", linewidth=1.8, zorder=4)
        # Ears
        ax.plot([-0.505, -0.525, -0.505], [0.05, 0.0, -0.05], color="black", linewidth=1.4, zorder=4)
        ax.plot([0.505, 0.525, 0.505], [0.05, 0.0, -0.05], color="black", linewidth=1.4, zorder=4)

    # Extract pairwise comparisons
    pairwise_info = etfce_result.get("pairwise", {}) if etfce_result else {}
    pairs = []
    for i in range(len(groups)):
        for j in range(i + 1, len(groups)):
            pairs.append((groups[i], groups[j]))

    # Calculate max difference magnitude for symmetric divergent colormap
    all_diff_vals = []
    for g1, g2 in pairs:
        for ch in ch_list:
            d = group_means[g2][ch] - group_means[g1][ch]
            if not math.isnan(d):
                all_diff_vals.append(d)
    max_abs_diff = max(1e-4, float(np.max(np.abs(all_diff_vals)))) if all_diff_vals else 0.1

    n_cols = max(len(groups), len(pairs))
    fig_w = max(4.0 * n_cols + 1.2, 10.5)
    fig_h = 7.5 if len(pairs) > 0 else 4.2
    fig = plt.figure(figsize=(fig_w, fig_h), dpi=300)

    if len(pairs) > 0:
        # Two rows: Row 0 = Means, Row 1 = Pairwise Differences, Column n_cols = Dedicated Colorbars
        gs = GridSpec(2, n_cols + 1, width_ratios=[1.0] * n_cols + [0.055], wspace=0.18, hspace=0.28)
        cax_means = fig.add_subplot(gs[0, n_cols])
        cax_diffs = fig.add_subplot(gs[1, n_cols])
    else:
        # Single row if only 1 group
        gs = GridSpec(1, n_cols + 1, width_ratios=[1.0] * n_cols + [0.055], wspace=0.18)
        cax_means = fig.add_subplot(gs[0, n_cols])
        cax_diffs = None

    # ── Row 1: Group Means ──────────────────────────────────────────────────
    cf_means = None
    for col_idx in range(n_cols):
        ax = fig.add_subplot(gs[0, col_idx])
        if col_idx < len(groups):
            g = groups[col_idx]
            vals = np.array([group_means[g][ch] for ch in ch_list])
            try:
                rbf = scipy.interpolate.Rbf(pts[:, 0], pts[:, 1], vals, function="multiquadric", smooth=0.01)
                zi = rbf(xi, yi)
            except Exception:
                zi = scipy.interpolate.griddata(pts, vals, (xi, yi), method="nearest")
            zi[~mask] = np.nan

            cf_means = ax.contourf(xi, yi, zi, levels=35, cmap="Spectral_r", vmin=g_min, vmax=g_max)
            ax.contour(xi, yi, zi, levels=7, colors="k", linewidths=0.35, alpha=0.3)
            draw_head_outline(ax)

            # Electrodes
            ax.scatter(pts[:, 0], pts[:, 1], color="#37474F", s=20, zorder=6)
            for ch in ch_list:
                x, y = matched[ch]
                norm_ch = normalize_channel_name(ch)
                txt = ax.text(x, y + 0.042, norm_ch, fontsize=7.5, ha="center", va="bottom", color="#263238", fontweight="bold", zorder=7)
                txt.set_path_effects([path_effects.withStroke(linewidth=2.0, foreground="white")])

            ax.set_title(f"{g} (Mean)", fontsize=11.5, fontweight="bold", pad=8)
            ax.set_xlim(-0.6, 0.6)
            ax.set_ylim(-0.6, 0.6)
            ax.set_aspect("equal", adjustable="box")
        ax.axis("off")

    if cf_means is not None and cax_means is not None:
        cbar1 = fig.colorbar(cf_means, cax=cax_means)
        cbar1.ax.tick_params(labelsize=8)
        cbar1.set_label("Group Mean", fontsize=9.5, fontweight="bold")

    # ── Row 2: Pairwise Differences with eTFCE ──────────────────────────────
    if len(pairs) > 0 and cax_diffs is not None:
        diff_norm = Normalize(vmin=-max_abs_diff, vmax=max_abs_diff)
        diff_sm = cm.ScalarMappable(norm=diff_norm, cmap="RdBu_r")

        for col_idx in range(n_cols):
            ax = fig.add_subplot(gs[1, col_idx])
            if col_idx < len(pairs):
                g1, g2 = pairs[col_idx]
                pair_key = f"{g2} - {g1}"
                p_res = pairwise_info.get(pair_key, pairwise_info.get(f"{g1} - {g2}", {}))
                sig_channels = set(p_res.get("sig_channels_etfce", []))

                diff_vals = np.array([group_means[g2][ch] - group_means[g1][ch] for ch in ch_list])
                try:
                    rbf = scipy.interpolate.Rbf(pts[:, 0], pts[:, 1], diff_vals, function="multiquadric", smooth=0.01)
                    zi = rbf(xi, yi)
                except Exception:
                    zi = scipy.interpolate.griddata(pts, diff_vals, (xi, yi), method="nearest")
                zi[~mask] = np.nan

                ax.contourf(xi, yi, zi, levels=35, cmap="RdBu_r", norm=diff_norm)
                ax.contour(xi, yi, zi, levels=7, colors="k", linewidths=0.35, alpha=0.3)
                draw_head_outline(ax)

                for ch in ch_list:
                    x, y = matched[ch]
                    norm_ch = normalize_channel_name(ch)
                    is_sig = ch in sig_channels or norm_ch in sig_channels
                    if is_sig:
                        # Highly prominent yellow star with black border
                        ax.scatter(x, y, marker="*", s=140, facecolor="#FFEE58", edgecolor="#000000", linewidths=1.0, zorder=10)
                        txt = ax.text(x, y + 0.042, f"{norm_ch}*", fontsize=8.5, ha="center", va="bottom", fontweight="bold", color="#b71c1c", zorder=11)
                        txt.set_path_effects([path_effects.withStroke(linewidth=2.5, foreground="white")])
                    else:
                        ax.scatter(x, y, s=18, facecolor="#37474F", edgecolor="#212121", linewidths=0.5, zorder=6)
                        txt = ax.text(x, y + 0.042, norm_ch, fontsize=7.5, ha="center", va="bottom", color="#263238", zorder=7)
                        txt.set_path_effects([path_effects.withStroke(linewidth=2.0, foreground="white")])

                min_p = p_res.get("min_p_etfce", 1.0)
                if sig_channels:
                    title_str = f"Diff: {pair_key}\n(p_eTFCE < {min_p:.3f}*)"
                    title_color = "#b71c1c"
                else:
                    title_str = f"Diff: {pair_key}\n(eTFCE ns, p={min_p:.3f})"
                    title_color = "#263238"

                ax.set_title(title_str, fontsize=10.5, fontweight="bold", pad=8, color=title_color)
                ax.set_xlim(-0.6, 0.6)
                ax.set_ylim(-0.6, 0.6)
                ax.set_aspect("equal", adjustable="box")
            ax.axis("off")

        cbar2 = fig.colorbar(diff_sm, cax=cax_diffs)
        cbar2.ax.tick_params(labelsize=8)
        cbar2.set_label("Pairwise Difference (\u0394)", fontsize=9.5, fontweight="bold")

    clean_metric_title = metric.replace("_", " ")
    fig.suptitle(
        f"Topographic Scalp Distribution (Topoplot) with Pairwise Robust eTFCE: {clean_metric_title}",
        fontsize=13,
        fontweight="bold",
        y=0.98,
    )
    output_png_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(str(output_png_path), dpi=300, bbox_inches="tight")
    plt.close(fig)
    return output_png_path


# ─── JOURNAL-FRIENDLY DOCX SCIENTIFIC REPORT ───────────────────────────────

def generate_docx_report(
    analysis_results: list[dict[str, Any]],
    meta_info: dict[str, Any],
    output_path: Path,
    plot_paths: dict[str, Path],
) -> Path:
    """Creates a publication-ready scientific Word document (.docx)."""
    if docx is None:
        return output_path

    doc = docx.Document()

    # Document Geometry: Standard 1 inch margins
    for section in doc.sections:
        section.top_margin = Inches(1.0)
        section.bottom_margin = Inches(1.0)
        section.left_margin = Inches(1.0)
        section.right_margin = Inches(1.0)

    # Styles setup
    style_normal = doc.styles["Normal"]
    style_normal.font.name = "Calibri"
    style_normal.font.size = Pt(10.5)
    style_normal.font.color.rgb = RGBColor(0x33, 0x33, 0x33)

    # ── Title & Header ─────────────────────────────────────────────────────
    title_p = doc.add_paragraph()
    title_p.paragraph_format.space_before = Pt(0)
    title_p.paragraph_format.space_after = Pt(4)
    run_title = title_p.add_run("Group-Level Statistical Analysis Report")
    run_title.font.name = "Calibri"
    run_title.font.size = Pt(22)
    run_title.font.bold = True
    run_title.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    sub_p = doc.add_paragraph()
    sub_p.paragraph_format.space_after = Pt(14)
    sub_run = sub_p.add_run(
        f"Sleep Neurophysiology & Macroarchitecture Cohort Comparison · "
        f"Generated: {datetime.datetime.now().strftime('%B %d, %Y at %H:%M')}\n"
        f"Source Dataset: {meta_info.get('source_csv_name', 'Master Sheet')} · "
        f"Cohorts: {meta_info.get('group_col')} · Sample Size: N = {meta_info.get('unique_subjects')} subjects"
    )
    sub_run.font.size = Pt(9.5)
    sub_run.font.italic = True
    sub_run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

    # ── 1. Executive Summary ───────────────────────────────────────────────
    h1 = doc.add_paragraph()
    h1.paragraph_format.space_before = Pt(14)
    h1.paragraph_format.space_after = Pt(6)
    r1 = h1.add_run("1. Executive Summary & Study Overview")
    r1.font.size = Pt(14)
    r1.font.bold = True
    r1.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    sig_metrics = [
        r["metric"] for r in analysis_results
        if any(e.get("q_value",e.get("p_value", 1.0)) < 0.05 for e in r.get("model_effects", []))
    ]

    exec_p = doc.add_paragraph()
    exec_p.paragraph_format.line_spacing = 1.15
    exec_p.paragraph_format.space_after = Pt(8)
    subgrp_str = f", structured across within-subject factor {meta_info.get('subgroup_col')}" if meta_info.get("subgroup_col") else ""
    exec_p.add_run(
        f"This report presents group-level comparative statistics on {len(analysis_results)} sleep EEG metrics "
        f"extracted across {meta_info.get('unique_subjects')} subjects and {meta_info.get('total_rows')} recording observations. "
        f"The primary grouping factor evaluated was '{meta_info.get('group_col')}'"
        f"{subgrp_str}. "
        f"A total of {len(sig_metrics)} metric(s) demonstrated statistically significant group main effects or interactions (p < 0.05): "
        f"{', '.join(sig_metrics[:8]) if sig_metrics else 'None reached statistical significance'}"
        f"{'...' if len(sig_metrics) > 8 else ''}."
    )

    # Executive Summary Overview Table
    t_sum_p = doc.add_paragraph()
    t_sum_p.paragraph_format.space_before = Pt(6)
    t_sum_p.paragraph_format.space_after = Pt(3)
    t_sum_run = t_sum_p.add_run("Table 1: Executive Summary of Analyzed Metrics & Findings")
    t_sum_run.font.bold = True
    t_sum_run.font.size = Pt(10)
    t_sum_run.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    t_summary = doc.add_table(rows=len(analysis_results) + 1, cols=5)
    t_summary.alignment = WD_TABLE_ALIGNMENT.CENTER
    sum_headers = ["Metric", "Model", "Omnibus Group Effect", "Key Pairwise Contrasts", "Scalp Cluster (eTFCE)"]
    for c_idx, h_text in enumerate(sum_headers):
        cell = t_summary.cell(0, c_idx)
        cell.text = h_text
        if cell.paragraphs[0].runs:
            cell.paragraphs[0].runs[0].font.bold = True
            cell.paragraphs[0].runs[0].font.size = Pt(9)
            cell.paragraphs[0].runs[0].font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    for r_idx, res in enumerate(analysis_results, start=1):
        clean_name = res["metric"].replace("_", " ")
        model_str = "LMM" if "Mixed" in res.get("model_type", "") else "GLM"

        grp_effects = [e for e in res.get("model_effects", []) if "group" in str(e.get("term", "")).lower() and ":" not in str(e.get("term", ""))]
        if grp_effects:
            eff = grp_effects[0]
            omni_str = f"{eff.get('stat_type','') }={eff.get('statistic',0):.2f}, p={format_p_value(eff.get('p_value',1.0))} ({eff.get('significance','ns')})"
        else:
            omni_str = "—"

        sig_ph = [p for p in res.get("posthoc_contrasts", []) if p.get("p_adj", p.get("p_raw", 1.0)) < 0.05]
        if sig_ph:
            ph_strs = [f"{p['group1']} vs {p['group2']}: d={p.get('cohen_d',0):.2f}, p={format_p_value(p.get('p_adj', p.get('p_raw',1.0)))}" for p in sig_ph[:2]]
            ph_summary = "; ".join(ph_strs)
            if len(sig_ph) > 2:
                ph_summary += f" (+{len(sig_ph)-2} more)"
        else:
            ph_summary = "None (ns)"

        etfce = res.get("etfce")
        if etfce and etfce.get("sig_channels_etfce"):
            etfce_summary = ", ".join(etfce["sig_channels_etfce"][:5])
            if len(etfce["sig_channels_etfce"]) > 5:
                etfce_summary += f" (+{len(etfce['sig_channels_etfce'])-5})"
            etfce_summary += " (p<0.05)"
        else:
            etfce_summary = "No cluster" if etfce else "N/A"

        for c_idx, val in enumerate([clean_name, model_str, omni_str, ph_summary, etfce_summary]):
            cell = t_summary.cell(r_idx, c_idx)
            cell.text = val
            if cell.paragraphs[0].runs:
                cell.paragraphs[0].runs[0].font.size = Pt(8.5)

    doc.add_paragraph().paragraph_format.space_after = Pt(8)

    # ── 2. Statistical Methodology ─────────────────────────────────────────
    h2 = doc.add_paragraph()
    h2.paragraph_format.space_before = Pt(14)
    h2.paragraph_format.space_after = Pt(6)
    r2 = h2.add_run("2. Statistical Methodology")
    r2.font.size = Pt(14)
    r2.font.bold = True
    r2.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    meth_p = doc.add_paragraph()
    meth_p.paragraph_format.line_spacing = 1.15
    meth_p.paragraph_format.space_after = Pt(8)
    meth_p.add_run(
        "Statistical analyses were conducted following state-of-the-art neurophysiology and sleep research guidelines. "
        "For multi-channel / regional features and repeated-measures observations within subjects, Linear Mixed-Effects Models (LMM) "
        "were implemented using Restricted Maximum Likelihood (REML) estimation with random intercepts for subject clustering: \n\n"
        "        Outcome ~ Group * Channel + Covariates + (1 | Subject)\n\n"
        "For macroarchitectural metrics with single observations per subject, General Linear Models (GLM / ANOVA Type II) were applied. "
        "Fixed-effect hypothesis testing was evaluated using Wald Chi-Square tests for LMM and F-tests for GLM. "
        "Post-hoc pairwise contrasts were adjusted for family-wise error rate using Benjamini-Hochberg False Discovery Rate (FDR) / "
        "Tukey's HSD. Standardized effect sizes are reported as Cohen's d for pairwise comparisons and partial eta squared (ηp²) "
        "for ANOVA main effects. Significance is designated as: * p < 0.05, ** p < 0.01, *** p < 0.001, **** p < 0.0001; ns = not significant."
    )

    # ── 3. Detailed Results & Plots ─────────────────────────────────────────
    h3 = doc.add_paragraph()
    h3.paragraph_format.space_before = Pt(16)
    h3.paragraph_format.space_after = Pt(6)
    r3 = h3.add_run("3. Metric-by-Metric Statistical Results")
    r3.font.size = Pt(14)
    r3.font.bold = True
    r3.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    for idx, res in enumerate(analysis_results, start=1):
        metric = res["metric"]
        clean_name = metric.replace("_", " ")

        mh = doc.add_paragraph()
        mh.paragraph_format.space_before = Pt(12)
        mh.paragraph_format.space_after = Pt(4)
        m_run = mh.add_run(f"3.{idx}  {clean_name} ({res['model_type']})")
        m_run.font.size = Pt(12)
        m_run.font.bold = True
        m_run.font.color.rgb = RGBColor(0x2B, 0x5C, 0x8F)

        # Narrative description
        effects = res.get("model_effects", [])
        sig_effects = [e for e in effects if e.get("q_value",e.get("p_value", 1.0)) < 0.05]
        narr_p = doc.add_paragraph()
        narr_p.paragraph_format.line_spacing = 1.15
        narr_p.paragraph_format.space_after = Pt(6)

        if sig_effects:
            eff_strs = [
                f"{e['term']} ({e['stat_type']} = {e['statistic']:.2f}, p = {format_p_value(e['p_value'])})"
                for e in sig_effects
            ]
            narr_p.add_run(
                f"Analysis of {clean_name} using a {res['model_type']} demonstrated significant main effect(s) for "
                f"{'; '.join(eff_strs)}. "
            )
        else:
            narr_p.add_run(
                f"Analysis of {clean_name} using a {res['model_type']} did not reveal statistically significant "
                f"group differences after multiple comparison adjustment (all p > 0.05). "
            )

        # Embedded Plot
        plot_path = plot_paths.get(metric)
        if plot_path and plot_path.exists():
            img_p = doc.add_paragraph()
            img_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            img_p.paragraph_format.space_before = Pt(4)
            img_p.paragraph_format.space_after = Pt(2)
            doc.add_picture(str(plot_path), width=Inches(5.5))

            cap_p = doc.add_paragraph()
            cap_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            cap_p.paragraph_format.space_after = Pt(8)
            cap_run = cap_p.add_run(f"Figure {idx}A: Distribution and post-hoc pairwise comparisons for {clean_name}.")
            cap_run.font.size = Pt(8.5)
            cap_run.font.italic = True
            cap_run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

        # Embedded Topoplot (if generated)
        topo_path = res.get("topoplot_path")
        if topo_path and Path(topo_path).exists():
            t_img_p = doc.add_paragraph()
            t_img_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            t_img_p.paragraph_format.space_before = Pt(4)
            t_img_p.paragraph_format.space_after = Pt(2)
            doc.add_picture(str(topo_path), width=Inches(5.8))

            t_cap_p = doc.add_paragraph()
            t_cap_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            t_cap_p.paragraph_format.space_after = Pt(10)
            t_cap_run = t_cap_p.add_run(f"Figure {idx}B: Topographic scalp distribution (Topoplot) across EEG derivations for {clean_name}.")
            t_cap_run.font.size = Pt(8.5)
            t_cap_run.font.italic = True
            t_cap_run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

        # Model Effects Table (APA Style)
        omnibus_effects = [e for e in effects if e.get("is_omnibus", True)]
        if not omnibus_effects and effects:
            omnibus_effects = effects

        if omnibus_effects:
            t_p = doc.add_paragraph()
            t_p.paragraph_format.space_before = Pt(6)
            t_p.paragraph_format.space_after = Pt(2)
            t_run = t_p.add_run(f"Table {idx}A: Model Omnibus Fixed Effects for {clean_name}")
            t_run.font.bold = True
            t_run.font.size = Pt(9.5)

            table = doc.add_table(rows=len(omnibus_effects) + 1, cols=7)
            table.alignment = WD_TABLE_ALIGNMENT.CENTER
            headers = ["Factor / Effect", "Stat Type", "Statistic", "df", "p (raw)", "p (FDR-adj)", "Sig."]
            for c_idx, h_text in enumerate(headers):
                cell = table.cell(0, c_idx)
                cell.text = h_text
                cell.paragraphs[0].runs[0].font.bold = True
                cell.paragraphs[0].runs[0].font.size = Pt(9)

            for r_idx, eff in enumerate(omnibus_effects, start=1):
                stat_val = f"{eff.get('statistic', 0.0):.3f}"
                df_val = f"{eff.get('df', 1)}" + (f", {eff.get('df_resid')}" if eff.get("df_resid") else "")
                p_raw_str = format_p_value(eff.get("p_value", 1.0))
                p_adj_str = format_p_value(eff.get("q_value", eff.get("p_value", 1.0)))
                sig_str = eff.get("significance", "ns")

                row_data = [
                    eff.get("term", ""),
                    eff.get("stat_type", ""),
                    stat_val,
                    df_val,
                    p_raw_str,
                    p_adj_str,
                    sig_str,
                ]
                for c_idx, val in enumerate(row_data):
                    cell = table.cell(r_idx, c_idx)
                    cell.text = val
                    if cell.paragraphs[0].runs:
                        cell.paragraphs[0].runs[0].font.size = Pt(8.5)

            doc.add_paragraph().paragraph_format.space_after = Pt(8)

        # Post-hoc pairwise comparisons table
        contrasts = res.get("posthoc_contrasts", [])
        sig_contrasts = [c for c in contrasts if c.get("significance", "ns") != "ns"]
        display_contrasts = contrasts if len(contrasts) <= 8 else sig_contrasts

        if display_contrasts:
            c_p = doc.add_paragraph()
            c_p.paragraph_format.space_before = Pt(4)
            c_p.paragraph_format.space_after = Pt(2)
            c_title = f"Table {idx}B: Post-Hoc Pairwise Contrasts for {clean_name}" + (" (Significant Only)" if len(contrasts) > 8 else "")
            c_run = c_p.add_run(c_title)
            c_run.font.bold = True
            c_run.font.size = Pt(9.5)

            c_table = doc.add_table(rows=len(display_contrasts) + 1, cols=7)
            c_table.alignment = WD_TABLE_ALIGNMENT.CENTER
            c_headers = ["Comparison", "Region / Level", "Mean Diff", "Cohen's d", "p (raw)", "p (FDR-adj)", "Sig."]
            for c_idx, h_text in enumerate(c_headers):
                cell = c_table.cell(0, c_idx)
                cell.text = h_text
                cell.paragraphs[0].runs[0].font.bold = True
                cell.paragraphs[0].runs[0].font.size = Pt(9)

            for r_idx, c in enumerate(display_contrasts, start=1):
                comp_str = f"{c.get('group1')} vs {c.get('group2')}"
                lvl_str = str(c.get("level") or c.get("factor") or "Overall")
                md_str = f"{c.get('mean_diff', 0.0):.3f}"
                cd_val = c.get("cohens_d")
                cd_str = f"{cd_val:.2f}" if cd_val is not None and not math.isnan(cd_val) else "—"
                p_raw_str = format_p_value(c.get("p_raw", 1.0))
                p_adj_str = format_p_value(c.get("p_adj", 1.0))
                sig_str = c.get("significance", "ns")

                row_data = [comp_str, lvl_str, md_str, cd_str, p_raw_str, p_adj_str, sig_str]
                for c_idx, val in enumerate(row_data):
                    cell = c_table.cell(r_idx, c_idx)
                    cell.text = val
                    if cell.paragraphs[0].runs:
                        cell.paragraphs[0].runs[0].font.size = Pt(8.5)

            doc.add_paragraph().paragraph_format.space_after = Pt(10)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(output_path))
    return output_path


# ─── PUBLICATION PDF SCIENTIFIC REPORT ──────────────────────────────────────

def generate_pdf_report(
    analysis_results: list[dict[str, Any]],
    meta_info: dict[str, Any],
    output_path: Path,
    plot_paths: dict[str, Path],
) -> Path:
    """Creates a publication-ready scientific PDF report using ReportLab."""
    if SimpleDocTemplate is None:
        return output_path

    doc = SimpleDocTemplate(
        str(output_path),
        pagesize=letter,
        rightMargin=45,
        leftMargin=45,
        topMargin=45,
        bottomMargin=45,
    )

    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "RepTitle",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=20,
        leading=24,
        textColor=colors.HexColor("#1F4E79"),
        spaceAfter=4,
    )
    subtitle_style = ParagraphStyle(
        "RepSubtitle",
        parent=styles["Normal"],
        fontName="Helvetica-Oblique",
        fontSize=9,
        leading=12,
        textColor=colors.HexColor("#666666"),
        spaceAfter=14,
    )
    h1_style = ParagraphStyle(
        "RepH1",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=13,
        leading=16,
        textColor=colors.HexColor("#1F4E79"),
        spaceBefore=12,
        spaceAfter=6,
    )
    h2_style = ParagraphStyle(
        "RepH2",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=11,
        leading=14,
        textColor=colors.HexColor("#2B5C8F"),
        spaceBefore=10,
        spaceAfter=4,
    )
    body_style = ParagraphStyle(
        "RepBody",
        parent=styles["Normal"],
        fontName="Helvetica",
        fontSize=9.5,
        leading=13,
        textColor=colors.HexColor("#333333"),
        spaceAfter=8,
    )
    caption_style = ParagraphStyle(
        "RepCaption",
        parent=styles["Normal"],
        fontName="Helvetica-Oblique",
        fontSize=8,
        leading=10,
        alignment=1,  # Centered
        textColor=colors.HexColor("#666666"),
        spaceAfter=10,
    )

    story = []

    # Title & Subtitle
    story.append(Paragraph("Group-Level Statistical Analysis Report", title_style))
    story.append(Paragraph(
        f"Sleep Neurophysiology & Macroarchitecture Cohort Comparison · "
        f"Generated: {datetime.datetime.now().strftime('%B %d, %Y at %H:%M')}<br/>"
        f"Source Dataset: {meta_info.get('source_csv_name', 'Master Sheet')} · "
        f"Cohort: {meta_info.get('group_col')} · Sample Size: N = {meta_info.get('unique_subjects')} subjects",
        subtitle_style,
    ))
    story.append(HRFlowable(width="100%", thickness=1.5, color=colors.HexColor("#1F4E79"), spaceAfter=10))

    # Executive Summary
    story.append(Paragraph("1. Executive Summary", h1_style))
    sig_count = sum(
        1 for r in analysis_results
        if any(e.get("q_value",e.get("p_value", 1.0)) < 0.05 for e in r.get("model_effects", []))
    )
    subgrp_pdf = f", structured across repeated factor <b>{meta_info.get('subgroup_col')}</b>" if meta_info.get("subgroup_col") else ""
    story.append(Paragraph(
        f"This report presents group-level comparative statistics across {len(analysis_results)} sleep metrics "
        f"derived from {meta_info.get('unique_subjects')} subjects. "
        f"Primary grouping factor: <b>{meta_info.get('group_col')}</b>"
        f"{subgrp_pdf}. "
        f"A total of <b>{sig_count}</b> metric(s) demonstrated statistically significant group effects (p &lt; 0.05).",
        body_style,
    ))

    # Executive Summary Table
    sum_data = [["Metric", "Model", "Omnibus Group Effect", "Key Contrasts", "Scalp Cluster (eTFCE)"]]
    for res in analysis_results:
        clean_name = res["metric"].replace("_", " ")
        model_str = "LMM" if "Mixed" in res.get("model_type", "") else "GLM"
        grp_effects = [e for e in res.get("model_effects", []) if "group" in str(e.get("term", "")).lower() and ":" not in str(e.get("term", ""))]
        if grp_effects:
            eff = grp_effects[0]
            omni_str = f"{eff.get('stat_type','')}={eff.get('statistic',0):.2f}, p={format_p_value(eff.get('p_value',1.0))}"
        else:
            omni_str = "—"
        sig_ph = [p for p in res.get("posthoc_contrasts", []) if p.get("p_adj", p.get("p_raw", 1.0)) < 0.05]
        if sig_ph:
            ph_summary = f"{len(sig_ph)} contrast(s) sig."
        else:
            ph_summary = "None (ns)"
        etfce = res.get("etfce")
        if etfce and etfce.get("sig_channels_etfce"):
            etfce_summary = f"{len(etfce['sig_channels_etfce'])} channels (p<0.05)"
        else:
            etfce_summary = "None" if etfce else "N/A"
        sum_data.append([clean_name, model_str, omni_str, ph_summary, etfce_summary])

    t_summary_pdf = Table(sum_data, colWidths=[120, 45, 130, 110, 115])
    t_summary_pdf.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1F4E79")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTNAME", (0, 0), (-1, -1), "Helvetica"),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("FONTSIZE", (0, 0), (-1, -1), 8),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#E2E8F0")),
    ]))
    story.append(t_summary_pdf)
    story.append(Spacer(1, 10))

    # Methodology
    story.append(Paragraph("2. Statistical Methodology", h1_style))
    story.append(Paragraph(
        "Multi-channel and repeated-measures sleep metrics were evaluated via <b>Linear Mixed-Effects Models (LMM)</b> "
        "utilizing Restricted Maximum Likelihood (REML) estimation with subject-level random intercepts: "
        "<i>Outcome ~ Group * Channel + Covariates + (1 | Subject)</i>. "
        "Single-observation macroarchitectural parameters were assessed using General Linear Models (GLM / ANOVA Type II). "
        "Significance was corrected using False Discovery Rate (FDR) / Tukey HSD (* p &lt; 0.05, ** p &lt; 0.01, *** p &lt; 0.001, **** p &lt; 0.0001).",
        body_style,
    ))

    # Metric Analyses & Figures
    story.append(Paragraph("3. Metric Statistical Results & Publication Plots", h1_style))

    for idx, res in enumerate(analysis_results, start=1):
        metric = res["metric"]
        clean_name = metric.replace("_", " ")
        story.append(Paragraph(f"3.{idx} {clean_name} ({res['model_type']})", h2_style))

        # Plot Image
        plot_path = plot_paths.get(metric)
        if plot_path and plot_path.exists():
            pw_pt, ph_pt = 5.5 * inch, 3.2 * inch
            if PILImage is not None:
                try:
                    with PILImage.open(str(plot_path)) as img:
                        pw, ph = img.size
                    aspect = ph / pw
                    pw_pt = 6.2 * inch
                    ph_pt = min(3.8 * inch, pw_pt * aspect)
                    pw_pt = ph_pt / aspect
                except Exception:
                    pass
            story.append(RLImage(str(plot_path), width=pw_pt, height=ph_pt))
            story.append(Paragraph(f"Figure {idx}A: Distribution and post-hoc pairwise significance for {clean_name}.", caption_style))

        # Topoplot Image (if available)
        topo_path = res.get("topoplot_path")
        if topo_path and Path(topo_path).exists():
            tw_pt, th_pt = 5.8 * inch, 3.5 * inch
            if PILImage is not None:
                try:
                    with PILImage.open(str(topo_path)) as img:
                        tpw, tph = img.size
                    aspect = tph / tpw
                    tw_pt = 6.5 * inch
                    th_pt = min(4.2 * inch, tw_pt * aspect)
                    tw_pt = th_pt / aspect
                except Exception:
                    pass
            story.append(RLImage(str(topo_path), width=tw_pt, height=th_pt))
            story.append(Paragraph(f"Figure {idx}B: Topographic scalp distribution (Topoplot) with pairwise robust eTFCE for {clean_name}.", caption_style))

        # Model Omnibus Effects Table
        effects = res.get("model_effects", [])
        omnibus_effects = [e for e in effects if e.get("is_omnibus", True)]
        if not omnibus_effects and effects:
            omnibus_effects = effects

        if omnibus_effects:
            table_data = [["Factor / Effect", "Stat Type", "Statistic", "df", "p (raw)", "p (FDR-adj)", "Sig."]]
            for eff in omnibus_effects:
                table_data.append([
                    eff.get("term", ""),
                    eff.get("stat_type", ""),
                    f"{eff.get('statistic', 0.0):.3f}",
                    f"{eff.get('df', 1)}" + (f", {eff.get('df_resid')}" if eff.get("df_resid") else ""),
                    format_p_value(eff.get("p_value", 1.0)),
                    format_p_value(eff.get("q_value", eff.get("p_value", 1.0))),
                    eff.get("significance", "ns"),
                ])
            t = Table(table_data, colWidths=[150, 55, 55, 45, 60, 65, 40])
            t.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#f0f4f8")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#1F4E79")),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 8),
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("LINEABOVE", (0, 0), (-1, 0), 1.0, colors.HexColor("#1F4E79")),
                ("LINEBELOW", (0, 0), (-1, 0), 1.0, colors.HexColor("#1F4E79")),
                ("LINEBELOW", (0, -1), (-1, -1), 1.0, colors.HexColor("#1F4E79")),
            ]))
            story.append(t)
            story.append(Spacer(1, 6))

        # Post-hoc pairwise comparisons table
        contrasts = res.get("posthoc_contrasts", [])
        sig_contrasts = [c for c in contrasts if c.get("significance", "ns") != "ns"]
        display_contrasts = contrasts if len(contrasts) <= 8 else sig_contrasts

        if display_contrasts:
            c_title = f"Post-Hoc Pairwise Contrasts: {clean_name}" + (" (Significant Only)" if len(contrasts) > 8 else "")
            story.append(Paragraph(f"<b>{c_title}</b>", caption_style))
            c_data = [["Comparison", "Region / Level", "Mean Diff", "Cohen's d", "p (raw)", "p (FDR-adj)", "Sig."]]
            for c in display_contrasts:
                comp_str = f"{c.get('group1')} vs {c.get('group2')}"
                lvl_str = str(c.get("level") or c.get("factor") or "Overall")
                md_str = f"{c.get('mean_diff', 0.0):.3f}"
                cd_val = c.get("cohens_d")
                cd_str = f"{cd_val:.2f}" if cd_val is not None and not math.isnan(cd_val) else "—"
                c_data.append([
                    comp_str,
                    lvl_str,
                    md_str,
                    cd_str,
                    format_p_value(c.get("p_raw", 1.0)),
                    format_p_value(c.get("p_adj", 1.0)),
                    c.get("significance", "ns"),
                ])
            ct = Table(c_data, colWidths=[120, 85, 60, 50, 55, 60, 40])
            ct.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#f8fafc")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#2C3E50")),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 7.5),
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5),
                ("TOPPADDING", (0, 0), (-1, -1), 2.5),
                ("LINEABOVE", (0, 0), (-1, 0), 0.8, colors.HexColor("#BDC3C7")),
                ("LINEBELOW", (0, 0), (-1, 0), 0.8, colors.HexColor("#BDC3C7")),
                ("LINEBELOW", (0, -1), (-1, -1), 0.8, colors.HexColor("#BDC3C7")),
            ]))
            story.append(ct)
            story.append(Spacer(1, 10))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    doc.build(story)
    return output_path


# ─── MAIN ORCHESTRATION ─────────────────────────────────────────────────────

def run_group_analysis(
    csv_path: Path,
    output_dir: Path | None = None,
    metadata_csv_path: Path | None = None,
    metadata_key_col: str | None = None,
    group_col: str | None = None,
    subgroup_col: str | None = None,
    covariates: list[str] | None = None,
    subject_id: str | None = None,
    metrics: list[str] | None = None,
    preferred_model: str = "auto",
    posthoc_method: str = "fdr",
    report_format: str = "both",  # 'docx', 'pdf', 'both'
    channel_scope: str = "roi",
    include_channels: list[str] | None = None,
    exclude_channels: list[str] | None = None,
    emit_json: bool = True,
) -> dict[str, Any]:
    """Runs the complete group-level analysis pipeline."""
    raw_csv = pd.read_csv(csv_path, low_memory=False)
    if raw_csv.columns.duplicated().any(): raise ValueError("Feature table contains duplicate column names")
    raw_table = prepare_eeg_table(raw_csv.copy(), metadata_csv_path, metadata_key_col)

    # Genuine scalp EEG dataset for topoplots and eTFCE (non-EEG channels strictly removed)
    raw_eeg_df = filter_eeg_channels(raw_table, include_non_eeg=False)
    if include_channels and "Chan" in raw_eeg_df.columns:
        raw_eeg_df = raw_eeg_df[raw_eeg_df["Chan"].astype(str).str.upper().isin([c.upper() for c in include_channels])]
    if exclude_channels and "Chan" in raw_eeg_df.columns:
        raw_eeg_df = raw_eeg_df[~raw_eeg_df["Chan"].astype(str).str.upper().isin([c.upper() for c in exclude_channels])]

    # Modeling dataset (clean ROIs, Mean, or individual channels)
    df = apply_channel_scope(
        raw_table,
        scope=channel_scope,
        include_non_eeg=False,
        include_channels=include_channels,
        exclude_channels=exclude_channels,
    )
    if sm is None:
        raise RuntimeError("Group modeling requires statsmodels. Install numpy pandas scipy matplotlib statsmodels python-docx reportlab openpyxl.")

    detected = detect_columns(df)
    final_subject_id = subject_id or detected["subject_id"]
    final_group_col = group_col or detected["group_col"]
    final_subgroup_col = subgroup_col or detected["subgroup_col"]
    final_covariates = covariates or detected["covariates"]

    if not final_group_col or final_group_col not in df.columns:
        raise ValueError(f"Could not determine valid grouping column in {csv_path.name}")
    if df[final_group_col].nunique()<2: raise ValueError("Choose a grouping factor with at least two levels")
    if final_subject_id and df[final_subject_id].nunique()<2: raise ValueError("Group inference requires multiple independent subjects")

    # Determine metrics to run
    available_metrics = detected["metric_columns"]
    if not metrics or metrics == ["auto"] or metrics == ["all"]:
        # Smart default: top relevant sleep metrics present in data
        prioritized = [
            "Sleep_efficiency", "TST", "WASO", "SOL", "N3_percentage", "R_percentage",
            "sp_Count", "sp_Duration", "sp_Amplitude", "sp_Frequency",
            "sw_Count", "sw_Density", "sw_Duration", "sw_Amplitude",
            "N3_Sigma_PSD", "N3_Delta_PSD", "N3_Theta_PSD", "CAP_rate", "CAP_A_index"
        ]
        target_metrics = [m for m in prioritized if m in available_metrics]
        if len(target_metrics) < 4:
            target_metrics = available_metrics[:15]
    else:
        target_metrics = [m for m in metrics if m in df.columns]

    # Create datastamped output folder
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    if output_dir:
        out_root = output_dir
    else:
        out_root = csv_path.parent / f"GroupStats_{timestamp}"
    out_root.mkdir(parents=True, exist_ok=True)
    plots_dir = out_root / "plots"
    plots_dir.mkdir(parents=True, exist_ok=True)

    analysis_results: list[dict[str, Any]] = []
    plot_paths: dict[str, Path] = {}
    all_model_effects: list[dict[str, Any]] = []
    all_posthoc_contrasts: list[dict[str, Any]] = []
    all_descriptives: list[dict[str, Any]] = []

    # Check topoplot feasibility on genuine scalp EEG channels
    is_topo_feasible = False
    raw_channel_col = None
    if "Chan" in raw_eeg_df.columns:
        channels_in_raw = [str(c) for c in raw_eeg_df["Chan"].dropna().unique()]
        is_topo_feasible, _ = check_topoplot_suitability(channels_in_raw)
        if is_topo_feasible:
            raw_channel_col = "Chan"

    total_metrics = len(target_metrics)
    for idx, m in enumerate(target_metrics):
        fraction = (idx + 1) / max(1, total_metrics)
        clean_name = m.replace("_", " ")
        sys.stderr.write(f"PROGRESS {fraction:.2f} Analyzing {idx+1}/{total_metrics}: {clean_name}\n")
        sys.stderr.flush()

        res = fit_statistical_model(
            df=df,
            metric=m,
            group_col=final_group_col,
            subgroup_col=final_subgroup_col,
            covariates=final_covariates,
            subject_id=final_subject_id,
            preferred_model=preferred_model,
            posthoc_method=posthoc_method,
        )
        if res:
            analysis_results.append(res)
            # Generate publication plot
            plot_file = plots_dir / f"{m}_plot.png"
            generate_publication_plot(res, df, plot_file)
            plot_paths[m] = plot_file

            # Generate topoplot & compute eTFCE if channel distribution is suitable and not invariant macroarchitecture
            if is_topo_feasible and not res.get("is_macroarchitecture", False):
                topo_file = plots_dir / f"{m}_topoplot.png"
                etfce_res = None
                try:
                    etfce_res = compute_etfce(
                        raw_df=raw_eeg_df,
                        metric=m,
                        group_col=final_group_col,
                        channel_col=raw_channel_col,
                        subject_id=final_subject_id,
                    )
                    if etfce_res:
                        res["etfce"] = etfce_res
                except Exception as e:
                    sys.stderr.write(f"eTFCE notice for {m}: {e}\n")

                topo_res = generate_topoplot(
                    raw_df=raw_eeg_df,
                    metric=m,
                    group_col=final_group_col,
                    channel_col=raw_channel_col,
                    posthoc_contrasts=res.get("posthoc_contrasts", []),
                    output_png_path=topo_file,
                    etfce_result=etfce_res,
                )
                if topo_res and topo_res.exists():
                    res["topoplot_path"] = str(topo_res)

            for eff in res.get("model_effects", []):
                all_model_effects.append({"metric": m, **eff})
            for ph in res.get("posthoc_contrasts", []):
                all_posthoc_contrasts.append({"metric": m, **ph})
            for ds in res.get("descriptive_stats", []):
                all_descriptives.append({"metric": m, **ds})

    # One correction family across the selected outcomes, not a fresh alpha
    # budget for every feature. Re-render plots with the final annotations.
    contrasts=[c for result in analysis_results for c in result.get("posthoc_contrasts",[])]
    finite=[c for c in contrasts if math.isfinite(c["p_raw"])]
    if finite:
        adjusted=multipletests([c["p_raw"] for c in finite],method="fdr_bh" if posthoc_method=="fdr" else "bonferroni")[1]
        for contrast,q in zip(finite,adjusted): contrast["p_adj"]=float(q);contrast["significance"]=p_to_star(float(q));contrast["correction_scope"]="all selected outcomes and contrasts"
    all_posthoc_contrasts=[{"metric":result["metric"],**contrast} for result in analysis_results for contrast in result.get("posthoc_contrasts",[])]
    for result in analysis_results:
        generate_publication_plot(result,df,plot_paths[result["metric"]])
        if result.get("topoplot_path"):
            generate_topoplot(
                raw_df=raw_eeg_df,
                metric=result["metric"],
                group_col=final_group_col,
                channel_col=raw_channel_col,
                posthoc_contrasts=result.get("posthoc_contrasts", []),
                output_png_path=Path(result["topoplot_path"]),
                etfce_result=result.get("etfce"),
            )

    # Correct omnibus and coefficient tests in separate selected-outcome families.
    for family in [("F","Chi2"),("z","t")]:
        effects=[effect for result in analysis_results for effect in result.get("model_effects",[]) if effect.get("stat_type") in family and math.isfinite(effect.get("p_value",float("nan")))]
        if effects:
            adjusted=multipletests([effect["p_value"] for effect in effects],method="fdr_bh" if posthoc_method=="fdr" else "bonferroni")[1]
            for effect,q in zip(effects,adjusted):effect["q_value"]=float(q);effect["significance"]=p_to_star(float(q))
    all_model_effects=[{"metric":result["metric"],**effect} for result in analysis_results for effect in result.get("model_effects",[])]

    # Save CSV Tables
    if not analysis_results: raise ValueError("No estimable outcomes: check subjects, missing values, and group sizes")
    if all_descriptives:
        pd.DataFrame(all_descriptives).to_csv(out_root / f"descriptive_statistics_{timestamp}.csv", index=False)
    if all_model_effects:
        pd.DataFrame(all_model_effects).to_csv(out_root / f"model_effects_{timestamp}.csv", index=False)
    if all_posthoc_contrasts:
        pd.DataFrame(all_posthoc_contrasts).to_csv(out_root / f"posthoc_comparisons_{timestamp}.csv", index=False)

    meta_summary = {
        "source_csv_name": csv_path.name,
        "source_csv_path": str(csv_path),
        "output_dir": str(out_root),
        "timestamp": timestamp,
        "group_col": final_group_col,
        "subgroup_col": final_subgroup_col,
        "covariates": final_covariates,
        "subject_id": final_subject_id,
        "total_rows": len(df),
        "unique_subjects": int(df[final_subject_id].nunique(dropna=True)) if final_subject_id else len(df),
        "metrics_analyzed": len(analysis_results),
        "channel_scope": channel_scope,
    }

    # Generate Reports
    docx_file = None
    pdf_file = None
    if report_format in ("docx", "both"):
        docx_file = out_root / f"Group_Statistical_Report_{timestamp}.docx"
        generate_docx_report(analysis_results, meta_summary, docx_file, plot_paths)

    if report_format in ("pdf", "both"):
        pdf_file = out_root / f"Group_Statistical_Report_{timestamp}.pdf"
        generate_pdf_report(analysis_results, meta_summary, pdf_file, plot_paths)

    # Clean results for JSON serialization (remove pandas objects)
    json_results = []
    for r in analysis_results:
        clean_r = {k: v for k, v in r.items() if k != "data_sample"}
        clean_r["plot_path"] = str(plot_paths.get(r["metric"], ""))
        if "topoplot_path" in r:
            clean_r["topoplot_path"] = str(r["topoplot_path"])
        json_results.append(clean_r)

    final_payload = {
        "status": "success",
        "metadata": meta_summary,
        "output_dir": str(out_root),
        "docx_path": str(docx_file) if docx_file and docx_file.exists() else None,
        "pdf_path": str(pdf_file) if pdf_file and pdf_file.exists() else None,
        "results": json_results,
    }

    with open(out_root / f"group_stats_summary_{timestamp}.json", "w", encoding="utf-8") as f:
        json.dump(final_payload, f, indent=2)

    return final_payload


def main() -> None:
    parser = argparse.ArgumentParser(description="CCS EEG Studio Group Statistical Analysis Engine")
    parser.add_argument("--csv", help="Input master analysis sheet CSV")
    parser.add_argument("--output-dir", help="Output directory for reports and plots")
    parser.add_argument("--metadata-csv", help="Optional metadata CSV/XLSX to merge")
    parser.add_argument("--metadata-key", help="Key column to join metadata")
    parser.add_argument("--group", help="Primary grouping column")
    parser.add_argument("--subgroup", help="Secondary / within-subject factor")
    parser.add_argument("--covariates", help="Comma-separated covariate column names")
    parser.add_argument("--subject-id", help="Subject identifier column")
    parser.add_argument("--metrics", help="Comma-separated metric column names")
    parser.add_argument("--model", choices=["auto", "lmm", "glm"], default="auto")
    parser.add_argument("--posthoc", choices=["fdr", "bonferroni"], default="fdr")
    parser.add_argument("--report-format", choices=["docx", "pdf", "both"], default="both")
    parser.add_argument("--inspect-only", action="store_true", help="Only inspect columns and return JSON")
    parser.add_argument("--channel", default="all", help="all, mean, roi, or a channel name")
    parser.add_argument("--include-channels", help="Comma-separated channel names to include")
    parser.add_argument("--exclude-channels", help="Comma-separated channel names to exclude")
    parser.add_argument("--config", help="Path to JSON configuration file")

    args = parser.parse_args()

    if args.config:
        with open(args.config, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        csv_file = Path(cfg["csv"])
        inspect_only = cfg.get("inspect_only", False)
        out_dir = Path(cfg["output_dir"]) if cfg.get("output_dir") else None
        meta_csv = Path(cfg["metadata_csv"]) if cfg.get("metadata_csv") else None
        meta_key = cfg.get("metadata_key")
        grp = cfg.get("group")
        subgrp = cfg.get("subgroup")
        covs = cfg.get("covariates", [])
        subjid = cfg.get("subject_id")
        mets = cfg.get("metrics")
        model = cfg.get("model", "auto")
        posthoc = cfg.get("posthoc", "fdr")
        rep_fmt = cfg.get("report_format", "both")
        chan_scope = cfg.get("channel", "all")
        inc_chans = cfg.get("include_channels")
        exc_chans = cfg.get("exclude_channels")
    else:
        if not args.csv:
            parser.print_help()
            sys.exit(1)
        csv_file = Path(args.csv)
        inspect_only = args.inspect_only
        out_dir = Path(args.output_dir) if args.output_dir else None
        meta_csv = Path(args.metadata_csv) if args.metadata_csv else None
        meta_key = args.metadata_key
        grp = args.group
        subgrp = args.subgroup
        covs = [c.strip() for c in args.covariates.split(",") if c.strip()] if args.covariates else []
        subjid = args.subject_id
        mets = [m.strip() for m in args.metrics.split(",") if m.strip()] if args.metrics else None
        model = args.model
        posthoc = args.posthoc
        rep_fmt = args.report_format
        chan_scope = args.channel
        inc_chans = [c.strip() for c in args.include_channels.split(",") if c.strip()] if getattr(args, "include_channels", None) else None
        exc_chans = [c.strip() for c in args.exclude_channels.split(",") if c.strip()] if getattr(args, "exclude_channels", None) else None

    if not csv_file.exists():
        sys.stderr.write(f"Error: CSV file not found: {csv_file}\n")
        sys.exit(1)

    if inspect_only:
        df = prepare_eeg_table(pd.read_csv(csv_file, low_memory=False), meta_csv, meta_key)
        detected = detect_columns(df)
        categorized = categorize_metrics(detected["metric_columns"])
        detected["categorized_metrics"] = categorized
        print(json.dumps(detected, indent=2))
        return

    payload = run_group_analysis(
        csv_path=csv_file,
        output_dir=out_dir,
        metadata_csv_path=meta_csv,
        metadata_key_col=meta_key,
        group_col=grp,
        subgroup_col=subgrp,
        covariates=covs,
        subject_id=subjid,
        metrics=mets,
        preferred_model=model,
        posthoc_method=posthoc,
        report_format=rep_fmt,
        channel_scope=chan_scope,
        include_channels=inc_chans,
        exclude_channels=exc_chans,
        emit_json=True,
    )
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
