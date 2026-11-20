//! Weighted graph-theory measures and Louvain community detection for connectivity matrices.
//!
//! Mirrors `tests/reference/graph_ref.py` (validated against bctpy / networkx on planted-community graphs).
//! Input is a connectivity matrix `raw[i][j]` (undirected: symmetric; directed: source i -> target j).
//! Negative / non-finite entries are treated as 0.  A proportional threshold keeps the strongest `density`
//! fraction of edges and normalises weights to (0, 1].  Path lengths are 1 / weight.
use std::collections::BTreeMap;

pub const NODE_NAMES: [&str; 8] = [
    "strength",
    "local_efficiency",
    "betweenness",
    "eigenvector",
    "participation",
    "within_module_z",
    "community",
    "net_flow",
];
pub const GLOBAL_NAMES: [&str; 7] = [
    "char_path_length",
    "mean_clustering",
    "transitivity",
    "modularity",
    "n_communities",
    "assortativity",
    "reciprocity",
];

#[derive(Debug, Clone)]
pub struct GraphResult {
    /// `node[i][k]` follows [`NODE_NAMES`].
    pub node: Vec<Vec<f64>>,
    /// Follows [`GLOBAL_NAMES`].
    pub global: Vec<f64>,
    /// Louvain community of every node (0 = largest).
    pub communities: Vec<usize>,
    /// Thresholded, max-normalised weight matrix the measures were computed on.
    pub weights: Vec<Vec<f64>>,
}

type Mat = Vec<Vec<f64>>;

fn clean(v: f64) -> f64 {
    if v.is_finite() { v.max(0.0) } else { 0.0 }
}

/// Positive proportional threshold. Undirected: symmetric mean projection over n(n-1)/2 pairs.
/// Directed: strongest edges among the n(n-1) directed edges.
pub fn threshold(raw: &[Vec<f64>], density: f64, directed: bool) -> Mat {
    let n = raw.len();
    let mut w = vec![vec![0.0; n]; n];
    let mut edges: Vec<(f64, usize, usize)> = Vec::new();
    if directed {
        for i in 0..n {
            for j in 0..n {
                let v = clean(raw[i][j]);
                if i != j && v > 0.0 {
                    edges.push((v, i, j));
                }
            }
        }
    } else {
        for i in 0..n {
            for j in 0..i {
                let v = clean(raw[i][j]) + clean(raw[j][i]);
                if v > 0.0 {
                    edges.push((v / 2.0, i, j));
                }
            }
        }
    }
    edges.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)).then(a.2.cmp(&b.2)));
    let total = if directed { n * (n.saturating_sub(1)) } else { n * (n.saturating_sub(1)) / 2 };
    let keep = (total as f64 * density).round() as usize;
    edges.truncate(keep);
    let Some(first) = edges.first().copied() else { return w };
    for &(v, i, j) in &edges {
        w[i][j] = v / first.0;
        if !directed {
            w[j][i] = v / first.0;
        }
    }
    w
}

fn lengths(w: &Mat) -> Mat {
    let n = w.len();
    let mut l = vec![vec![f64::INFINITY; n]; n];
    for i in 0..n {
        for j in 0..n {
            if i == j {
                l[i][j] = 0.0;
            } else if w[i][j] > 0.0 {
                l[i][j] = 1.0 / w[i][j];
            }
        }
    }
    l
}

fn shortest_paths(l: &Mat) -> Mat {
    let n = l.len();
    let mut d = l.clone();
    for k in 0..n {
        for i in 0..n {
            let dik = d[i][k];
            if !dik.is_finite() {
                continue;
            }
            for j in 0..n {
                let c = dik + d[k][j];
                if c < d[i][j] {
                    d[i][j] = c;
                }
            }
        }
    }
    d
}

fn inverse_sum(d: &Mat) -> f64 {
    let mut s = 0.0;
    for (i, r) in d.iter().enumerate() {
        for (j, &v) in r.iter().enumerate() {
            if i != j && v.is_finite() && v > 0.0 {
                s += 1.0 / v;
            }
        }
    }
    s
}

fn matmul(a: &Mat, b: &Mat) -> Mat {
    let n = a.len();
    let mut c = vec![vec![0.0; n]; n];
    for i in 0..n {
        for k in 0..n {
            let aik = a[i][k];
            if aik == 0.0 {
                continue;
            }
            for j in 0..n {
                c[i][j] += aik * b[k][j];
            }
        }
    }
    c
}

fn cube_root_sym(w: &Mat, directed: bool) -> Mat {
    let n = w.len();
    let r: Mat = w.iter().map(|row| row.iter().map(|v| v.cbrt()).collect()).collect();
    if !directed {
        return r;
    }
    (0..n).map(|i| (0..n).map(|j| r[i][j] + r[j][i]).collect()).collect()
}

fn trace_cube(s: &Mat) -> Vec<f64> {
    let s2 = matmul(s, s);
    let n = s.len();
    (0..n).map(|i| (0..n).map(|k| s2[i][k] * s[k][i]).sum()).collect()
}

fn degrees(w: &Mat) -> (Vec<f64>, Vec<f64>, Vec<f64>) {
    // (total degree, out degree, number of reciprocal partners)
    let n = w.len();
    let mut tot = vec![0.0; n];
    let mut bi = vec![0.0; n];
    for i in 0..n {
        for j in 0..n {
            if i == j {
                continue;
            }
            if w[i][j] > 0.0 {
                tot[i] += 1.0;
            }
            if w[j][i] > 0.0 {
                tot[i] += 1.0;
            }
            if w[i][j] > 0.0 && w[j][i] > 0.0 {
                bi[i] += 1.0;
            }
        }
    }
    let out = (0..n).map(|i| (0..n).filter(|&j| w[i][j] > 0.0).count() as f64).collect();
    (tot, out, bi)
}

/// Onnela (undirected) / Fagiolo (directed) weighted clustering coefficient.
pub fn clustering(w: &Mat, directed: bool) -> Vec<f64> {
    let n = w.len();
    let s = cube_root_sym(w, directed);
    let t = trace_cube(&s);
    let (tot, out, bi) = degrees(w);
    (0..n)
        .map(|i| {
            if directed {
                let den = tot[i] * (tot[i] - 1.0) - 2.0 * bi[i];
                if den > 0.0 { t[i] / 2.0 / den } else { 0.0 }
            } else {
                let k = out[i];
                if k > 1.0 { t[i] / (k * (k - 1.0)) } else { 0.0 }
            }
        })
        .collect()
}

pub fn transitivity(w: &Mat, directed: bool) -> f64 {
    let n = w.len();
    let s = cube_root_sym(w, directed);
    let t: f64 = trace_cube(&s).iter().sum();
    let (tot, out, bi) = degrees(w);
    if directed {
        let den: f64 = (0..n).map(|i| tot[i] * (tot[i] - 1.0) - 2.0 * bi[i]).sum();
        if den > 0.0 { t / 2.0 / den } else { 0.0 }
    } else {
        let den: f64 = out.iter().map(|k| k * (k - 1.0)).sum();
        if den > 0.0 { t / den } else { 0.0 }
    }
}

fn local_efficiency(w: &Mat) -> Vec<f64> {
    let n = w.len();
    (0..n)
        .map(|i| {
            let nb: Vec<usize> = (0..n).filter(|&j| j != i && (w[i][j] > 0.0 || w[j][i] > 0.0)).collect();
            let k = nb.len();
            if k < 2 {
                return 0.0;
            }
            let sub: Mat = nb.iter().map(|&a| nb.iter().map(|&b| w[a][b]).collect()).collect();
            inverse_sum(&shortest_paths(&lengths(&sub))) / (k * (k - 1)) as f64
        })
        .collect()
}

/// Brandes betweenness on a dense length matrix, normalised by (n-1)(n-2).
fn betweenness(l: &Mat) -> Vec<f64> {
    let n = l.len();
    let mut bc = vec![0.0; n];
    let eps = 1e-12;
    for s in 0..n {
        let mut dist = vec![f64::INFINITY; n];
        let mut sigma = vec![0.0; n];
        let mut done = vec![false; n];
        let mut order = Vec::with_capacity(n);
        let mut pred: Vec<Vec<usize>> = vec![Vec::new(); n];
        dist[s] = 0.0;
        sigma[s] = 1.0;
        for _ in 0..n {
            let mut u = usize::MAX;
            let mut best = f64::INFINITY;
            for v in 0..n {
                if !done[v] && dist[v] < best {
                    best = dist[v];
                    u = v;
                }
            }
            if u == usize::MAX {
                break;
            }
            done[u] = true;
            order.push(u);
            for v in 0..n {
                if v == u || !l[u][v].is_finite() {
                    continue;
                }
                let nd = dist[u] + l[u][v];
                let tol = eps * nd.abs().max(1.0);
                if nd < dist[v] - tol {
                    dist[v] = nd;
                    sigma[v] = sigma[u];
                    pred[v] = vec![u];
                } else if (nd - dist[v]).abs() <= tol && !done[v] {
                    sigma[v] += sigma[u];
                    pred[v].push(u);
                }
            }
        }
        let mut delta = vec![0.0; n];
        for &v in order.iter().rev() {
            for &u in &pred[v] {
                delta[u] += sigma[u] / sigma[v] * (1.0 + delta[v]);
            }
            if v != s {
                bc[v] += delta[v];
            }
        }
    }
    if n > 2 {
        let norm = ((n - 1) * (n - 2)) as f64;
        bc.iter_mut().for_each(|v| *v /= norm);
    }
    bc
}

fn eigenvector(w: &Mat, directed: bool) -> Vec<f64> {
    let n = w.len();
    let mut x = vec![1.0 / (n as f64).sqrt(); n];
    for _ in 0..2000 {
        // y = A x + x  (the identity shift avoids oscillation on bipartite graphs); directed uses in-edges
        let mut y: Vec<f64> = (0..n)
            .map(|i| (0..n).map(|j| if directed { w[j][i] } else { w[i][j] } * x[j]).sum::<f64>() + x[i])
            .collect();
        let nr = y.iter().map(|v| v * v).sum::<f64>().sqrt();
        if nr == 0.0 {
            return vec![0.0; n];
        }
        y.iter_mut().for_each(|v| *v /= nr);
        let diff = y.iter().zip(&x).map(|(a, b)| (a - b).abs()).fold(0.0, f64::max);
        x = y;
        if diff < 1e-12 {
            break;
        }
    }
    x.iter().map(|v| v.abs()).collect()
}

/// Newman-Leicht directed modularity (reduces to the usual weighted modularity for symmetric input).
pub fn modularity(a: &Mat, comm: &[usize], gamma: f64) -> f64 {
    let n = a.len();
    let m: f64 = a.iter().map(|r| r.iter().sum::<f64>()).sum();
    if m <= 0.0 {
        return 0.0;
    }
    let ko: Vec<f64> = a.iter().map(|r| r.iter().sum()).collect();
    let ki: Vec<f64> = (0..n).map(|j| (0..n).map(|i| a[i][j]).sum()).collect();
    let mut q = 0.0;
    for i in 0..n {
        for j in 0..n {
            if comm[i] == comm[j] {
                q += a[i][j] - gamma * ko[i] * ki[j] / m;
            }
        }
    }
    q / m
}

struct Rng(u64);
impl Rng {
    fn new(seed: u64) -> Self {
        let s = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        Rng(if s == 0 { 1 } else { s })
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
    fn shuffle(&mut self, v: &mut [usize]) {
        for i in (1..v.len()).rev() {
            let j = (self.next() % (i as u64 + 1)) as usize;
            v.swap(i, j);
        }
    }
}

fn louvain_once(a: &Mat, gamma: f64, rng: &mut Rng) -> Vec<usize> {
    let n0 = a.len();
    let mut comm_of: Vec<usize> = (0..n0).collect();
    let mut cur = a.clone();
    loop {
        let n = cur.len();
        let m: f64 = cur.iter().map(|r| r.iter().sum::<f64>()).sum();
        if m <= 0.0 {
            break;
        }
        let ko: Vec<f64> = cur.iter().map(|r| r.iter().sum()).collect();
        let ki: Vec<f64> = (0..n).map(|j| (0..n).map(|i| cur[i][j]).sum()).collect();
        let mut c: Vec<usize> = (0..n).collect();
        let mut sout = ko.clone();
        let mut sin = ki.clone();
        let mut moved_any = false;
        loop {
            let mut moved = false;
            let mut order: Vec<usize> = (0..n).collect();
            rng.shuffle(&mut order);
            for &i in &order {
                let ci = c[i];
                sout[ci] -= ko[i];
                sin[ci] -= ki[i];
                let mut kin_c: BTreeMap<usize, f64> = BTreeMap::new();
                for j in 0..n {
                    if j == i {
                        continue;
                    }
                    let (w_io, w_oi) = (cur[i][j], cur[j][i]);
                    if w_io != 0.0 || w_oi != 0.0 {
                        *kin_c.entry(c[j]).or_insert(0.0) += w_io + w_oi;
                    }
                }
                kin_c.entry(ci).or_insert(0.0);
                let gain = |cc: usize, k: f64| k - gamma * (ko[i] * sin[cc] + ki[i] * sout[cc]) / m;
                let mut best = ci;
                let mut bg = gain(ci, kin_c[&ci]);
                for (&cc, &k) in &kin_c {
                    let g = gain(cc, k);
                    if g > bg + 1e-12 {
                        best = cc;
                        bg = g;
                    }
                }
                c[i] = best;
                sout[best] += ko[i];
                sin[best] += ki[i];
                if best != ci {
                    moved = true;
                    moved_any = true;
                }
            }
            if !moved {
                break;
            }
        }
        if !moved_any {
            break;
        }
        let mut labels: Vec<usize> = c.clone();
        labels.sort_unstable();
        labels.dedup();
        let remap: BTreeMap<usize, usize> = labels.iter().enumerate().map(|(k, &l)| (l, k)).collect();
        let c: Vec<usize> = c.iter().map(|x| remap[x]).collect();
        comm_of = comm_of.iter().map(|&x| c[x]).collect();
        let k = labels.len();
        if k == n {
            break;
        }
        let mut next = vec![vec![0.0; k]; k];
        for i in 0..n {
            for j in 0..n {
                next[c[i]][c[j]] += cur[i][j];
            }
        }
        cur = next;
    }
    comm_of
}

/// Louvain with `restarts` seeded random node orders; the best modularity wins. Communities are relabelled by
/// descending size (ties: lowest node index) so output is deterministic. Directed input uses directed modularity.
pub fn louvain(a: &Mat, gamma: f64, restarts: usize, seed: u64) -> (Vec<usize>, f64) {
    let mut best: Vec<usize> = vec![0; a.len()];
    let mut bq = f64::NEG_INFINITY;
    for r in 0..restarts.max(1) {
        let comm = louvain_once(a, gamma, &mut Rng::new(seed + r as u64));
        let q = modularity(a, &comm, gamma);
        if q > bq + 1e-12 {
            bq = q;
            best = comm;
        }
    }
    let mut size: BTreeMap<usize, usize> = BTreeMap::new();
    let mut first: BTreeMap<usize, usize> = BTreeMap::new();
    for (i, &c) in best.iter().enumerate() {
        *size.entry(c).or_insert(0) += 1;
        first.entry(c).or_insert(i);
    }
    let mut ranked: Vec<usize> = size.keys().copied().collect();
    ranked.sort_by(|a, b| size[b].cmp(&size[a]).then(first[a].cmp(&first[b])));
    let map: BTreeMap<usize, usize> = ranked.iter().enumerate().map(|(k, &c)| (c, k)).collect();
    (best.iter().map(|c| map[c]).collect(), if bq.is_finite() { bq } else { 0.0 })
}

fn participation_and_z(w: &Mat, comm: &[usize]) -> (Vec<f64>, Vec<f64>) {
    let n = w.len();
    let sym = (0..n).all(|i| (0..n).all(|j| (w[i][j] - w[j][i]).abs() < 1e-12));
    let s: Mat = if sym { w.clone() } else { (0..n).map(|i| (0..n).map(|j| w[i][j] + w[j][i]).collect()).collect() };
    let k: Vec<f64> = s.iter().map(|r| r.iter().sum()).collect();
    let nc = comm.iter().copied().max().map(|m| m + 1).unwrap_or(0);
    let mut p = vec![0.0; n];
    let mut z = vec![0.0; n];
    for i in 0..n {
        if k[i] > 0.0 {
            let mut acc = 0.0;
            for c in 0..nc {
                let kc: f64 = (0..n).filter(|&j| comm[j] == c).map(|j| s[i][j]).sum();
                acc += (kc / k[i]).powi(2);
            }
            p[i] = 1.0 - acc;
        }
    }
    for c in 0..nc {
        let idx: Vec<usize> = (0..n).filter(|&i| comm[i] == c).collect();
        let kin: Vec<f64> = idx.iter().map(|&i| idx.iter().map(|&j| s[i][j]).sum()).collect();
        let mean = kin.iter().sum::<f64>() / kin.len().max(1) as f64;
        let sd = (kin.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / kin.len().max(1) as f64).sqrt();
        for (a, &i) in idx.iter().enumerate() {
            z[i] = if idx.len() > 1 && sd > 0.0 { (kin[a] - mean) / sd } else { 0.0 };
        }
    }
    (p, z)
}

fn assortativity(w: &Mat, directed: bool) -> f64 {
    let n = w.len();
    let so: Vec<f64> = w.iter().map(|r| r.iter().sum()).collect();
    let si: Vec<f64> = (0..n).map(|j| (0..n).map(|i| w[i][j]).sum()).collect();
    let (mut sw, mut sa, mut sb, mut saa, mut sbb, mut sab) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    for i in 0..n {
        for j in 0..n {
            let wt = w[i][j];
            if wt <= 0.0 {
                continue;
            }
            let (a, b) = if directed { (so[i], si[j]) } else { (so[i], so[j]) };
            sw += wt;
            sa += wt * a;
            sb += wt * b;
            saa += wt * a * a;
            sbb += wt * b * b;
            sab += wt * a * b;
        }
    }
    if sw <= 0.0 {
        return f64::NAN;
    }
    let (ma, mb) = (sa / sw, sb / sw);
    let (va, vb) = (saa / sw - ma * ma, sbb / sw - mb * mb);
    if va <= 0.0 || vb <= 0.0 {
        return f64::NAN;
    }
    (sab / sw - ma * mb) / (va * vb).sqrt()
}

/// All node and global measures of one connectivity matrix.
pub fn analyze(raw: &[Vec<f64>], directed: bool, density: f64, gamma: f64, restarts: usize, seed: u64) -> GraphResult {
    let n = raw.len();
    if n < 3 || raw.iter().any(|r| r.len() != n) {
        return GraphResult {
            node: vec![vec![f64::NAN; NODE_NAMES.len()]; n],
            global: vec![f64::NAN; GLOBAL_NAMES.len()],
            communities: vec![0; n],
            weights: vec![vec![0.0; n]; n],
        };
    }
    let w = threshold(raw, density, directed);
    let l = lengths(&w);
    let d = shortest_paths(&l);
    let so: Vec<f64> = w.iter().map(|r| r.iter().sum()).collect();
    let si: Vec<f64> = (0..n).map(|j| (0..n).map(|i| w[i][j]).sum()).collect();
    let total: f64 = so.iter().sum();
    let (comm, q) = if total > 0.0 { louvain(&w, gamma, restarts, seed) } else { (vec![0; n], 0.0) };
    let (p, z) = participation_and_z(&w, &comm);
    let le = local_efficiency(&w);
    let bc = betweenness(&l);
    let ev = eigenvector(&w, directed);
    let node: Vec<Vec<f64>> = (0..n)
        .map(|i| {
            let flow = so[i] + si[i];
            vec![
                if directed { flow } else { so[i] },
                le[i],
                bc[i],
                ev[i],
                p[i],
                z[i],
                comm[i] as f64,
                if !directed {
                    f64::NAN
                } else if flow > 0.0 {
                    (so[i] - si[i]) / flow
                } else {
                    0.0
                },
            ]
        })
        .collect();
    let mut sum = 0.0;
    let mut count = 0usize;
    for i in 0..n {
        for j in 0..n {
            if i != j && d[i][j].is_finite() {
                sum += d[i][j];
                count += 1;
            }
        }
    }
    let cl = clustering(&w, directed);
    let reciprocity = if directed && total > 0.0 {
        let mut s = 0.0;
        for i in 0..n {
            for j in 0..n {
                if i != j {
                    s += w[i][j].min(w[j][i]);
                }
            }
        }
        s / total
    } else {
        f64::NAN
    };
    let global = vec![
        if count > 0 { sum / count as f64 } else { f64::NAN },
        cl.iter().sum::<f64>() / n as f64,
        transitivity(&w, directed),
        q,
        comm.iter().copied().max().map(|m| (m + 1) as f64).unwrap_or(0.0),
        assortativity(&w, directed),
        reciprocity,
    ];
    GraphResult { node, global, communities: comm, weights: w }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn planted(n_per: usize, groups: usize, within: f64, between: f64) -> Mat {
        let n = n_per * groups;
        let mut a = vec![vec![0.0; n]; n];
        let mut state = 12345u64;
        let mut rnd = || {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((state >> 33) as f64) / (1u64 << 31) as f64
        };
        for i in 0..n {
            for j in 0..i {
                let same = i / n_per == j / n_per;
                let v = if same { within + 0.2 * rnd() } else { between * rnd() };
                a[i][j] = v;
                a[j][i] = v;
            }
        }
        a
    }

    #[test]
    fn louvain_recovers_planted_communities() {
        let a = planted(6, 3, 0.8, 0.15);
        let r = analyze(&a, false, 0.4, 1.0, 10, 1);
        assert_eq!(r.global[4] as usize, 3);
        for g in 0..3 {
            let first = r.communities[g * 6];
            assert!((0..6).all(|k| r.communities[g * 6 + k] == first));
        }
        assert!(r.global[3] > 0.3, "modularity {}", r.global[3]);
        let again = analyze(&a, false, 0.4, 1.0, 10, 1);
        assert_eq!(r.communities, again.communities, "deterministic for a fixed seed");
    }

    #[test]
    fn directed_net_flow_marks_sources_and_sinks() {
        let n = 8;
        let mut a = vec![vec![0.0; n]; n];
        for i in 0..4 {
            for j in 4..8 {
                a[i][j] = 1.0 + 0.01 * (i + j) as f64; // 0..3 drive 4..7
            }
        }
        let r = analyze(&a, true, 1.0, 1.0, 5, 1);
        assert!((0..4).all(|i| r.node[i][7] > 0.9), "sources have positive net flow");
        assert!((4..8).all(|i| r.node[i][7] < -0.9), "sinks have negative net flow");
        assert!(r.global[6] < 1e-9, "no reciprocal edges");
    }

    #[test]
    fn undirected_matrix_has_no_net_flow_and_symmetric_strengths() {
        let a = planted(4, 2, 0.8, 0.1);
        let r = analyze(&a, false, 0.5, 1.0, 3, 1);
        assert!(r.node.iter().all(|row| row[7].is_nan()));
        assert!(r.global[6].is_nan());
    }

    #[test]
    fn complete_graph_has_unit_clustering_and_efficiency() {
        let n = 5;
        let a: Mat = (0..n).map(|i| (0..n).map(|j| if i == j { 0.0 } else { 1.0 }).collect()).collect();
        let w = threshold(&a, 1.0, false);
        assert!(clustering(&w, false).iter().all(|c| (c - 1.0).abs() < 1e-12));
        assert!((transitivity(&w, false) - 1.0).abs() < 1e-12);
    }
}
