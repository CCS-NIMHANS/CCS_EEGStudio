"""Python mirror of information.rs gcmi_matrix / temporal_te_matrix (Frites-style Gaussian copula)."""
import numpy as np
from scipy.special import digamma
from scipy.stats import norm, rankdata

def copnorm(x):
    r = rankdata(x, method='ordinal'); return norm.ppf(r / (len(x) + 1))

def _ent(vs):
    v = np.vstack(vs); p, n = v.shape
    c = np.cov(v)
    if p == 1: c = np.atleast_2d(c)
    L = np.linalg.cholesky(c); h = np.log(np.diag(L)).sum()
    return h - p * (np.log(2) - np.log(n - 1)) / 2 - sum(digamma((n - k) / 2) / 2 for k in range(1, p + 1))

def mi(x, y): return (_ent([x]) + _ent([y]) - _ent([x, y])) / 2 / np.log(2) * 2 / 2 * 1.0 if False else (_ent([x]) + _ent([y]) - _ent([x, y])) / np.log(2)

def gcmi_matrix(ch):
    z = [copnorm(c) for c in ch]; n = len(z); w = np.zeros((n, n))
    for i in range(n):
        for j in range(i): w[i, j] = w[j, i] = mi(z[i], z[j])
    return w

def te_matrix(ch, delay=1, ns=1, nt=1, step=1):
    n, T = ch.shape; hist = max(delay + (ns - 1) * step, 1 + (nt - 1) * step); lo = hist
    emb = lambda c, lag: copnorm(ch[c, lo - lag:T - lag])
    pres = [emb(c, 0) for c in range(n)]; tpast = [[emb(c, 1 + h * step) for h in range(nt)] for c in range(n)]
    w = np.zeros((n, n))
    for i in range(n):
        sp = [emb(i, delay + h * step) for h in range(ns)]
        for j in range(n):
            if i == j: continue
            z = tpast[j]; yz = [pres[j]] + z
            w[i, j] = (_ent(sp + z) + _ent(yz) - _ent(sp + yz) - _ent(z)) / np.log(2)
    return w
