"""Reference implementation (numpy) mirrored 1:1 by bridge/vendor/ccs_algorithm/src/eeg/graph_theory.rs."""
import numpy as np

def threshold(raw, density, directed):
    """Positive proportional threshold. Undirected: symmetric mean projection, top density of n(n-1)/2 pairs.
    Directed: top density of the n(n-1) directed edges. Weights normalised by max -> (0,1]."""
    n = len(raw); raw = np.nan_to_num(np.asarray(raw, float)); raw = np.maximum(raw, 0); np.fill_diagonal(raw, 0)
    w = np.zeros((n, n))
    if directed:
        e = [(raw[i, j], i, j) for i in range(n) for j in range(n) if i != j and raw[i, j] > 0]
        e.sort(key=lambda t: (-t[0], t[1], t[2]))
        keep = int(round(n * (n - 1) * density)); e = e[:keep]
        if not e: return w
        mx = e[0][0]
        for v, i, j in e: w[i, j] = v / mx
    else:
        e = [((raw[i, j] + raw[j, i]) / 2, i, j) for i in range(n) for j in range(i) if (raw[i, j] + raw[j, i]) > 0]
        e.sort(key=lambda t: (-t[0], t[1], t[2]))
        keep = int(round(n * (n - 1) / 2 * density)); e = e[:keep]
        if not e: return w
        mx = e[0][0]
        for v, i, j in e: w[i, j] = w[j, i] = v / mx
    return w

def distances(w):
    n = len(w); L = np.full((n, n), np.inf); L[w > 0] = 1.0 / w[w > 0]; np.fill_diagonal(L, 0)
    D = L.copy()
    for k in range(n):
        D = np.minimum(D, D[:, [k]] + D[[k], :])
    return D, L

def efficiency_nodal(D):
    n = len(D); inv = np.where((D > 0) & np.isfinite(D), 1.0 / np.where(D > 0, D, 1), 0.0)
    return inv.sum(1) / (n - 1)

def local_efficiency(w, directed):
    n = len(w); out = np.zeros(n)
    for i in range(n):
        nb = [j for j in range(n) if j != i and (w[i, j] > 0 or w[j, i] > 0)]
        k = len(nb)
        if k < 2: continue
        sub = w[np.ix_(nb, nb)]
        D, _ = distances(sub)
        inv = np.where((D > 0) & np.isfinite(D), 1.0 / np.where(D > 0, D, 1), 0.0)
        out[i] = inv.sum() / (k * (k - 1))
    return out

def clustering(w, directed):
    n = len(w); c = np.zeros(n)
    if not directed:
        r = np.cbrt(w); t = np.diag(r @ r @ r); k = (w > 0).sum(1)
        for i in range(n):
            if k[i] > 1: c[i] = t[i] / (k[i] * (k[i] - 1))
        return c
    r = np.cbrt(w); s = r + r.T; t = np.diag(s @ s @ s) / 2.0
    dtot = (w > 0).sum(0) + (w > 0).sum(1); dbi = ((w > 0) & (w.T > 0)).sum(1)
    den = dtot * (dtot - 1) - 2 * dbi
    return np.where(den > 0, t / np.where(den > 0, den, 1), 0.0)

def transitivity(w, directed):
    if directed:
        k = ((w > 0).sum(0) + (w > 0).sum(1)).astype(float); r = np.cbrt(w); s = r + r.T
        t = np.diag(s @ s @ s).sum() / 2.0; bi = ((w > 0) & (w.T > 0)).sum(1)
        den = (k * (k - 1) - 2 * bi).sum(); return t / den if den > 0 else 0.0
    k = (w > 0).sum(1).astype(float); r = np.cbrt(w); t = np.diag(r @ r @ r).sum(); den = (k * (k - 1)).sum()
    return t / den if den > 0 else 0.0

def betweenness(L):
    """Brandes on dense length matrix L (inf = no edge). Normalised by (n-1)(n-2)."""
    n = len(L); bc = np.zeros(n); eps = 1e-12
    for s in range(n):
        dist = np.full(n, np.inf); dist[s] = 0; sigma = np.zeros(n); sigma[s] = 1
        done = np.zeros(bool_n := n, bool); order = []; pred = [[] for _ in range(n)]
        for _ in range(n):
            u = -1; best = np.inf
            for v in range(n):
                if not done[v] and dist[v] < best: best = dist[v]; u = v
            if u < 0: break
            done[u] = True; order.append(u)
            for v in range(n):
                if v == u or not np.isfinite(L[u, v]): continue
                nd = dist[u] + L[u, v]
                if nd < dist[v] - eps * max(1, abs(nd)): dist[v] = nd; sigma[v] = sigma[u]; pred[v] = [u]
                elif abs(nd - dist[v]) <= eps * max(1, abs(nd)) and not done[v]: sigma[v] += sigma[u]; pred[v].append(u)
        delta = np.zeros(n)
        for v in reversed(order):
            for u in pred[v]: delta[u] += sigma[u] / sigma[v] * (1 + delta[v])
            if v != s: bc[v] += delta[v]
    return bc / ((n - 1) * (n - 2)) if n > 2 else bc

def eigenvector(w, directed):
    n = len(w); a = w.T if directed else w; x = np.ones(n) / np.sqrt(n)
    for _ in range(2000):
        y = a @ x + x; nr = np.linalg.norm(y)
        if nr == 0: return np.zeros(n)
        y /= nr
        if np.abs(y - x).max() < 1e-12: x = y; break
        x = y
    return np.abs(x)

def modularity(A, comm, gamma=1.0):
    m = A.sum()
    if m <= 0: return 0.0
    ko = A.sum(1); ki = A.sum(0); q = 0.0
    n = len(A)
    for i in range(n):
        for j in range(n):
            if comm[i] == comm[j]: q += A[i, j] - gamma * ko[i] * ki[j] / m
    return q / m

class _Rng:
    def __init__(self, seed): self.s = (seed * 6364136223846793005 + 1442695040888963407) & (2**64 - 1) or 1
    def next(self):
        x = self.s; x ^= (x << 13) & (2**64 - 1); x ^= x >> 7; x ^= (x << 17) & (2**64 - 1); self.s = x; return x
    def shuffle(self, v):
        for i in range(len(v) - 1, 0, -1):
            j = self.next() % (i + 1); v[i], v[j] = v[j], v[i]

def _louvain_once(A, gamma, rng):
    n0 = len(A); comm_of = list(range(n0)); cur = A.copy()
    while True:
        n = len(cur); m = cur.sum()
        if m <= 0: break
        ko = cur.sum(1); ki = cur.sum(0); c = list(range(n)); sout = ko.copy(); sin = ki.copy(); moved_any = False
        while True:
            moved = False; order = list(range(n)); rng.shuffle(order)
            for i in order:
                ci = c[i]; sout[ci] -= ko[i]; sin[ci] -= ki[i]
                kin_c = {};
                for j in range(n):
                    if j == i: continue
                    w_io = cur[i, j]; w_oi = cur[j, i]
                    if w_io != 0 or w_oi != 0: kin_c[c[j]] = kin_c.get(c[j], 0.0) + w_io + w_oi
                kin_c.setdefault(ci, 0.0)
                best, bg = ci, kin_c[ci] - gamma * (ko[i] * sin[ci] + ki[i] * sout[ci]) / m
                for cc in sorted(kin_c):
                    g = kin_c[cc] - gamma * (ko[i] * sin[cc] + ki[i] * sout[cc]) / m
                    if g > bg + 1e-12: best, bg = cc, g
                c[i] = best; sout[best] += ko[i]; sin[best] += ki[i]
                if best != ci: moved = True; moved_any = True
            if not moved: break
        if not moved_any: break
        labs = sorted(set(c)); remap = {l: k for k, l in enumerate(labs)}; c = [remap[x] for x in c]
        comm_of = [c[x] for x in comm_of]; k = len(labs)
        nxt = np.zeros((k, k))
        for i in range(n):
            for j in range(n): nxt[c[i], c[j]] += cur[i, j]
        if k == n: break
        cur = nxt
    return comm_of

def louvain(A, gamma=1.0, restarts=10, seed=1):
    best = None; bq = -np.inf
    for r in range(restarts):
        comm = _louvain_once(A, gamma, _Rng(seed + r)); q = modularity(A, comm, gamma)
        if q > bq + 1e-12: bq, best = q, comm
    labs = {}
    for c in best: labs[c] = labs.get(c, 0) + 1
    first = {}
    for i, c in enumerate(best): first.setdefault(c, i)
    rank = sorted(labs, key=lambda c: (-labs[c], first[c])); mp = {c: k for k, c in enumerate(rank)}
    return [mp[c] for c in best], bq

def participation_and_z(w, comm):
    n = len(w); s = w + w.T if not np.allclose(w, w.T) else w
    k = s.sum(1); nc = max(comm) + 1; P = np.zeros(n); z = np.zeros(n)
    for i in range(n):
        if k[i] > 0: P[i] = 1 - sum((s[i, [j for j in range(n) if comm[j] == c]].sum() / k[i]) ** 2 for c in range(nc))
    for c in range(nc):
        idx = [i for i in range(n) if comm[i] == c]
        kin = np.array([s[i, idx].sum() for i in idx])
        sd = kin.std(ddof=0)
        for a, i in enumerate(idx): z[i] = (kin[a] - kin.mean()) / sd if len(idx) > 1 and sd > 0 else 0.0
    return P, z

def assortativity(w, directed):
    n = len(w)
    if directed:
        so, si = w.sum(1), w.sum(0); e = [(w[i, j], so[i], si[j]) for i in range(n) for j in range(n) if w[i, j] > 0]
    else:
        s = w.sum(1); e = [(w[i, j], s[i], s[j]) for i in range(n) for j in range(n) if w[i, j] > 0]
    if not e: return float('nan')
    wt = np.array([x[0] for x in e]); a = np.array([x[1] for x in e]); b = np.array([x[2] for x in e]); W = wt.sum()
    ma, mb = (wt * a).sum() / W, (wt * b).sum() / W
    va, vb = (wt * a * a).sum() / W - ma ** 2, (wt * b * b).sum() / W - mb ** 2
    if va <= 0 or vb <= 0: return float('nan')
    return ((wt * a * b).sum() / W - ma * mb) / np.sqrt(va * vb)

NODE = ["strength", "local_efficiency", "betweenness", "eigenvector", "participation", "within_module_z", "community", "net_flow"]
GLOBAL = ["char_path_length", "mean_clustering", "transitivity", "modularity", "n_communities", "assortativity", "reciprocity"]

def analyze(raw, directed=False, density=0.2, gamma=1.0, restarts=10, seed=1):
    n = len(raw); w = threshold(raw, density, directed)
    D, L = distances(w); so, si = w.sum(1), w.sum(0)
    comm, q = louvain(w if directed else w, gamma, restarts, seed) if w.sum() > 0 else ([0] * n, 0.0)
    P, z = participation_and_z(w, comm)
    off = ~np.eye(n, dtype=bool); fin = off & np.isfinite(D)
    node = {
        "strength": so + si if directed else so,
        "local_efficiency": local_efficiency(w, directed),
        "betweenness": betweenness(L),
        "eigenvector": eigenvector(w, directed),
        "participation": P, "within_module_z": z, "community": np.array(comm, float),
        "net_flow": np.where(so + si > 0, (so - si) / np.where(so + si > 0, so + si, 1), 0.0) if directed else np.full(n, np.nan),
    }
    rec = float(np.minimum(w, w.T)[off].sum() / w.sum()) if directed and w.sum() > 0 else float('nan')
    g = {"char_path_length": D[fin].mean() if fin.any() else float('nan'),
         "mean_clustering": clustering(w, directed).mean(), "transitivity": transitivity(w, directed),
         "modularity": q, "n_communities": float(max(comm) + 1), "assortativity": assortativity(w, directed), "reciprocity": rec}
    return node, g, w
