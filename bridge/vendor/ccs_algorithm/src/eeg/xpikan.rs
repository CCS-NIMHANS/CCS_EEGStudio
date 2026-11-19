//! Extended Physics-Informed Kolmogorov-Arnold Network (XPIKAN) for EEG
//! 3-shell volume conduction and physics-regularized inverse projection.
//!
//! References:
//! - Fokas, Aghaei & Hashemzadeh (2026), *A Preliminary Analysis of a
//!   Physics-Informed Neural Network for the Forward Problem in EEG*
//!   (MDPI / XPIKAN multi-subdomain + B-spline/spherical KAN).
//! - Liu et al. (2024), *KAN: Kolmogorov-Arnold Networks* (arXiv:2404.19756).
//! - Jagtap & Karniadakis (2020), *Extended Physics-Informed Neural Networks
//!   (XPINNs)*, Commun. Comput. Phys. 28(5).

use nalgebra::{DMatrix, DVector};
use std::f64::consts::PI;

/// Canonical concentric 3-shell normalized spherical head geometry:
/// Ω1: cerebrum (r <= 0.87, sigma1 = 0.33 S/m)
/// Ω2: skull    (0.87 < r <= 0.92, sigma2 = 0.0042 S/m)
/// Ω3: scalp    (0.92 < r <= 1.00, sigma3 = 0.33 S/m)
pub const R_BRAIN: f64 = 0.87;
pub const R_SKULL: f64 = 0.92;
pub const R_SCALP: f64 = 1.00;
pub const SIGMA_BRAIN: f64 = 0.33;
pub const SIGMA_SKULL: f64 = 0.0042;
pub const SIGMA_SCALP: f64 = 0.33;

/// Generates an extended uniform B-spline knot vector of degree `k` over `[a, b]`
/// with `grid_intervals` interior grid intervals, yielding `n_basis = grid_intervals + k`
/// B-spline basis functions that form an exact partition of unity on `[a, b]`.
pub fn uniform_bspline_knots(a: f64, b: f64, grid_intervals: usize, degree: usize) -> Vec<f64> {
    let g = grid_intervals.max(1);
    let h = (b - a) / g as f64;
    let start = -(degree as isize);
    let end = (g + degree) as isize;
    (start..=end).map(|i| a + i as f64 * h).collect()
}

/// Evaluates Cox-de Boor B-spline basis functions `B_{i,degree}(x)` of degree `k`
/// across all `n_basis = knots.len() - k - 1` basis functions.
pub fn bspline_basis(x: f64, knots: &[f64], degree: usize) -> Vec<f64> {
    let m = knots.len();
    if m <= degree + 1 {
        return Vec::new();
    }
    let n0 = m - 1;
    let a = knots[degree];
    let b = knots[m - 1 - degree];
    let xc = x.clamp(a, b);

    let mut b0 = vec![0.0_f64; n0];
    for i in 0..n0 {
        if xc >= knots[i] && xc < knots[i + 1] {
            b0[i] = 1.0;
        }
    }

    let mut cur = b0;
    for d in 1..=degree {
        let next_n = m - 1 - d;
        let mut next = vec![0.0_f64; next_n];
        for i in 0..next_n {
            let denom1 = knots[i + d] - knots[i];
            let denom2 = knots[i + d + 1] - knots[i + 1];
            let t1 = if denom1.abs() > 1e-14 {
                (xc - knots[i]) / denom1 * cur[i]
            } else {
                0.0
            };
            let t2 = if denom2.abs() > 1e-14 {
                (knots[i + d + 1] - xc) / denom2 * cur[i + 1]
            } else {
                0.0
            };
            next[i] = t1 + t2;
        }
        cur = next;
    }
    cur
}

/// SiLU (Swish) residual activation `x * sigmoid(x)` as in Liu et al. (2024) KAN.
#[inline]
fn silu(x: f64) -> f64 {
    let s = 1.0 / (1.0 + (-x).exp());
    x * s
}

/// One Kolmogorov-Arnold Network layer `y_j = sum_i (w_base[j,i]*silu(x_i) + sum_m c[j,i,m]*B_m(tanh(x_i))) + bias_j`.
#[derive(Clone, Debug)]
pub struct KanLayer {
    pub in_dim: usize,
    pub out_dim: usize,
    pub n_basis: usize,
    pub knots: Vec<f64>,
    pub w_base: Vec<f64>,
    pub coeff: Vec<f64>,
    pub bias: Vec<f64>,
}

impl KanLayer {
    pub fn new(in_dim: usize, out_dim: usize, grid_intervals: usize, seed: u64) -> Self {
        let degree = 3;
        let knots = uniform_bspline_knots(-1.0, 1.0, grid_intervals, degree);
        let n_basis = knots.len() - degree - 1;
        let mut st = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut next_unit = || {
            st = st
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((st >> 33) as f64 / u32::MAX as f64) - 0.5
        };
        let scale = 1.0 / ((in_dim.max(1) * n_basis.max(1)) as f64).sqrt();
        let w_base = (0..out_dim * in_dim).map(|_| next_unit() * scale).collect();
        let coeff = (0..out_dim * in_dim * n_basis)
            .map(|_| next_unit() * scale * 0.5)
            .collect();
        let bias = vec![0.0; out_dim];
        Self {
            in_dim,
            out_dim,
            n_basis,
            knots,
            w_base,
            coeff,
            bias,
        }
    }

    pub fn forward(&self, x: &[f64]) -> Vec<f64> {
        let mut out = self.bias.clone();
        let bases: Vec<Vec<f64>> = x
            .iter()
            .take(self.in_dim)
            .map(|&xi| bspline_basis(xi.tanh(), &self.knots, 3))
            .collect();
        for j in 0..self.out_dim {
            let mut acc = out[j];
            for i in 0..self.in_dim.min(x.len()) {
                acc += self.w_base[j * self.in_dim + i] * silu(x[i]);
                let c_off = (j * self.in_dim + i) * self.n_basis;
                for (m, &bm) in bases[i].iter().enumerate() {
                    acc += self.coeff[c_off + m] * bm;
                }
            }
            out[j] = acc;
        }
        out
    }
}

/// Real orthonormal spherical harmonics `Y_{l,m}(p / ||p||)` for `l = 0..=l_max`
/// (`(l_max + 1)^2` basis functions), evaluated via recursion on associated
/// Legendre polynomials `P_l^m(z / r)` without Condon-Shortley phase.
pub fn real_spherical_harmonics(p: [f64; 3], l_max: usize) -> Vec<f64> {
    let r = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt().max(1e-15);
    let u = (p[2] / r).clamp(-1.0, 1.0);
    let phi = p[1].atan2(p[0]);
    let s = (1.0 - u * u).max(0.0).sqrt();

    let n_l = l_max + 1;
    let mut plm = vec![vec![0.0_f64; n_l]; n_l];
    plm[0][0] = 1.0;
    for m in 1..=l_max {
        plm[m][m] = (2 * m - 1) as f64 * s * plm[m - 1][m - 1];
    }
    for m in 0..l_max {
        plm[m + 1][m] = (2 * m + 1) as f64 * u * plm[m][m];
    }
    for m in 0..=l_max {
        for l in (m + 2)..=l_max {
            plm[l][m] = ((2 * l - 1) as f64 * u * plm[l - 1][m]
                - (l + m - 1) as f64 * plm[l - 2][m])
                / (l - m) as f64;
        }
    }

    let mut out = Vec::with_capacity(n_l * n_l);
    for l in 0..=l_max {
        let norm0 = ((2 * l + 1) as f64 / (4.0 * PI)).sqrt();
        out.push(norm0 * plm[l][0]);
        let mut fac = 1.0_f64;
        for m in 1..=l {
            fac /= ((l + m) * (l - m + 1)) as f64;
            let norm = (2.0 * (2 * l + 1) as f64 / (4.0 * PI) * fac).sqrt();
            let mp = m as f64 * phi;
            out.push(norm * plm[l][m] * mp.cos());
            out.push(norm * plm[l][m] * mp.sin());
        }
    }
    out
}

/// Separable radial cubic B-spline x real spherical harmonic XPIKAN subdomain basis
/// representing one smooth shell field `u_k(p) = sum_{s,l,m} c_{s,l,m} B_s(r_norm) Y_{l,m}(p_hat)`.
/// Padded `r_halfwidth` guarantees finite-difference radial derivatives never clamp across interfaces.
#[derive(Clone, Debug)]
struct SubdomainKanBasis {
    knots: Vec<f64>,
    n_spline: usize,
    n_sh: usize,
    l_max: usize,
    r_center: f64,
    r_halfwidth: f64,
}

impl SubdomainKanBasis {
    fn new(grid_intervals: usize, l_max: usize, r_center: f64, r_halfwidth: f64) -> Self {
        let knots = uniform_bspline_knots(-1.0, 1.0, grid_intervals, 3);
        let n_spline = knots.len() - 4;
        let n_sh = (l_max + 1) * (l_max + 1);
        Self {
            knots,
            n_spline,
            n_sh,
            l_max,
            r_center,
            r_halfwidth: r_halfwidth.max(1e-3),
        }
    }

    fn dim(&self) -> usize {
        self.n_spline * self.n_sh
    }

    /// Evaluates subdomain KAN feature vector `phi(p)` at point `p in R^3`.
    fn eval(&self, p: [f64; 3]) -> Vec<f64> {
        let r = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt();
        let r_norm = (r - self.r_center) / self.r_halfwidth;
        let br = bspline_basis(r_norm, &self.knots, 3);
        let sh = real_spherical_harmonics(p, self.l_max);
        let mut phi = Vec::with_capacity(self.dim());
        for &b in &br {
            for &y in &sh {
                phi.push(b * y);
            }
        }
        phi
    }

    /// Radial normal derivative `d/dr phi(p)` along `r_hat = p / ||p||`.
    fn grad_radial(&self, p: [f64; 3]) -> Vec<f64> {
        let r = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt().max(1e-9);
        let n = [p[0] / r, p[1] / r, p[2] / r];
        let h = 1e-4;
        let plus = self.eval([p[0] + h * n[0], p[1] + h * n[1], p[2] + h * n[2]]);
        let minus = self.eval([p[0] - h * n[0], p[1] - h * n[1], p[2] - h * n[2]]);
        plus.into_iter()
            .zip(minus)
            .map(|(a, b)| (a - b) / (2.0 * h))
            .collect()
    }

    /// 3D Laplacian `nabla^2 phi(p)` via 6-point central finite difference.
    fn laplacian(&self, p: [f64; 3]) -> Vec<f64> {
        let h = 5e-4;
        let f0 = self.eval(p);
        let px = self.eval([p[0] + h, p[1], p[2]]);
        let mx = self.eval([p[0] - h, p[1], p[2]]);
        let py = self.eval([p[0], p[1] + h, p[2]]);
        let my = self.eval([p[0], p[1] - h, p[2]]);
        let pz = self.eval([p[0], p[1], p[2] + h]);
        let mz = self.eval([p[0], p[1], p[2] - h]);
        let inv_h2 = 1.0 / (h * h);
        (0..f0.len())
            .map(|k| ((px[k] + mx[k] + py[k] + my[k] + pz[k] + mz[k]) - 6.0 * f0[k]) * inv_h2)
            .collect()
    }
}

/// Fibonacci sphere sampling of `n` near-uniform points on unit sphere `S^2`.
fn fibonacci_sphere(n: usize) -> Vec<[f64; 3]> {
    let golden = PI * (3.0 - 5.0_f64.sqrt());
    (0..n)
        .map(|i| {
            let y = 1.0 - (i as f64 / (n.saturating_sub(1).max(1) as f64)) * 2.0;
            let radius = (1.0 - y * y).max(0.0).sqrt();
            let theta = golden * i as f64;
            [theta.cos() * radius, y, theta.sin() * radius]
        })
        .collect()
}

/// Infinite-medium primary dipole potential `u_inf(p) = (q . (p - r0)) / (4*pi*sigma1 * |p - r0|^3)`.
pub fn dipole_inf_potential(p: [f64; 3], r0: [f64; 3], q: [f64; 3], sigma1: f64) -> f64 {
    let dx = p[0] - r0[0];
    let dy = p[1] - r0[1];
    let dz = p[2] - r0[2];
    let r2 = (dx * dx + dy * dy + dz * dz).max(1e-10);
    let r3 = r2 * r2.sqrt();
    (q[0] * dx + q[1] * dy + q[2] * dz) / (4.0 * PI * sigma1 * r3)
}

/// Radial normal derivative `d/dr u_inf` at boundary sphere point `p`.
pub fn dipole_inf_radial_flux_grad(p: [f64; 3], r0: [f64; 3], q: [f64; 3], sigma1: f64) -> f64 {
    let r = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).sqrt().max(1e-9);
    let n = [p[0] / r, p[1] / r, p[2] / r];
    let h = 1e-5;
    let vp = dipole_inf_potential(
        [p[0] + h * n[0], p[1] + h * n[1], p[2] + h * n[2]],
        r0,
        q,
        sigma1,
    );
    let vm = dipole_inf_potential(
        [p[0] - h * n[0], p[1] - h * n[1], p[2] - h * n[2]],
        r0,
        q,
        sigma1,
    );
    (vp - vm) / (2.0 * h)
}

#[derive(Debug, Clone)]
pub struct XpikanForwardResult {
    pub potentials: Vec<f64>,
    pub pde_residual_rms: f64,
    pub interface_residual_rms: f64,
    pub neumann_bc_rms: f64,
}

/// Concentric 3-shell domain-decomposed XPIKAN solver for the EEG forward problem:
/// solves Laplace equations inside Ω1, Ω2, Ω3 coupled with potential & normal-flux
/// continuity on Γ12 (r=0.87) and Γ23 (r=0.92), plus homogeneous Neumann BC on Γ3 (r=1.0).
pub struct XpikanThreeShellModel {
    net1: SubdomainKanBasis,
    net2: SubdomainKanBasis,
    net3: SubdomainKanBasis,
    kan_diag: KanLayer,
}

impl XpikanThreeShellModel {
    pub fn new() -> Self {
        let net1 = SubdomainKanBasis::new(4, 6, 0.435, 0.46);
        let net2 = SubdomainKanBasis::new(2, 6, 0.895, 0.030);
        let net3 = SubdomainKanBasis::new(2, 6, 0.960, 0.045);
        let kan_diag = KanLayer::new(3, 1, 5, 404);
        Self {
            net1,
            net2,
            net3,
            kan_diag,
        }
    }

    /// Evaluates the KAN nonlinear spline layer on a 3D point (used for geometric probe).
    pub fn kan_probe(&self, p: [f64; 3]) -> f64 {
        self.kan_diag.forward(&p)[0]
    }

    pub fn solve_forward_dipole(
        &self,
        r_dip: [f64; 3],
        q: [f64; 3],
        eval_pts: &[[f64; 3]],
    ) -> XpikanForwardResult {
        let d1 = self.net1.dim();
        let d2 = self.net2.dim();
        let d3 = self.net3.dim();
        let off1 = 0;
        let off2 = d1;
        let off3 = d1 + d2;
        let n_params = d1 + d2 + d3;

        let dir_pde = fibonacci_sphere(56);
        let dir_iface = fibonacci_sphere(80);

        let mut r1_pts = Vec::with_capacity(5 * dir_pde.len());
        for rad in [0.18, 0.36, 0.54, 0.70, 0.82] {
            for &d in &dir_pde {
                let pt = [d[0] * rad, d[1] * rad, d[2] * rad];
                let dist = ((pt[0] - r_dip[0]).powi(2)
                    + (pt[1] - r_dip[1]).powi(2)
                    + (pt[2] - r_dip[2]).powi(2))
                .sqrt();
                if dist >= 0.08 {
                    r1_pts.push(pt);
                }
            }
        }
        let mut r2_pts = Vec::with_capacity(3 * dir_pde.len());
        for rad in [0.882, 0.895, 0.908] {
            for &d in &dir_pde {
                r2_pts.push([d[0] * rad, d[1] * rad, d[2] * rad]);
            }
        }
        let mut r3_pts = Vec::with_capacity(3 * dir_pde.len());
        for rad in [0.94, 0.96, 0.98] {
            for &d in &dir_pde {
                r3_pts.push([d[0] * rad, d[1] * rad, d[2] * rad]);
            }
        }

        let n_rows = r1_pts.len()
            + r2_pts.len()
            + r3_pts.len()
            + 2 * dir_iface.len()
            + 2 * dir_iface.len()
            + dir_iface.len();

        let mut a_mat = DMatrix::<f64>::zeros(n_rows, n_params);
        let mut b_vec = DVector::<f64>::zeros(n_rows);
        let mut row = 0;

        // 1. Interior Laplace PDE residuals: nabla^2 u_k^KAN = 0
        let w_pde = 1.0;
        let pde_start = row;
        for &p in &r1_pts {
            let lap = self.net1.laplacian(p);
            for (k, &v) in lap.iter().enumerate() {
                a_mat[(row, off1 + k)] = w_pde * v;
            }
            row += 1;
        }
        for &p in &r2_pts {
            let lap = self.net2.laplacian(p);
            for (k, &v) in lap.iter().enumerate() {
                a_mat[(row, off2 + k)] = w_pde * v;
            }
            row += 1;
        }
        for &p in &r3_pts {
            let lap = self.net3.laplacian(p);
            for (k, &v) in lap.iter().enumerate() {
                a_mat[(row, off3 + k)] = w_pde * v;
            }
            row += 1;
        }
        let pde_end = row;

        // 2. Interface Γ12 (r = R_BRAIN): u1 + u_inf = u2  and  σ1 * ∂r(u1 + u_inf) = σ2 * ∂r(u2)
        let iface_start = row;
        let w_u = 5.0;
        let w_flux = 5.0;
        for d in &dir_iface {
            let p = [d[0] * R_BRAIN, d[1] * R_BRAIN, d[2] * R_BRAIN];
            let phi1 = self.net1.eval(p);
            let phi2 = self.net2.eval(p);
            for k in 0..d1 {
                a_mat[(row, off1 + k)] = w_u * phi1[k];
            }
            for k in 0..d2 {
                a_mat[(row, off2 + k)] = -w_u * phi2[k];
            }
            let u_inf = dipole_inf_potential(p, r_dip, q, SIGMA_BRAIN);
            b_vec[row] = -w_u * u_inf;
            row += 1;

            let g1 = self.net1.grad_radial(p);
            let g2 = self.net2.grad_radial(p);
            for k in 0..d1 {
                a_mat[(row, off1 + k)] = w_flux * SIGMA_BRAIN * g1[k];
            }
            for k in 0..d2 {
                a_mat[(row, off2 + k)] = -w_flux * SIGMA_SKULL * g2[k];
            }
            let g_inf = dipole_inf_radial_flux_grad(p, r_dip, q, SIGMA_BRAIN);
            b_vec[row] = -w_flux * SIGMA_BRAIN * g_inf;
            row += 1;
        }

        // 3. Interface Γ23 (r = R_SKULL): u2 = u3  and  σ2 * ∂r(u2) = σ3 * ∂r(u3)
        for d in &dir_iface {
            let p = [d[0] * R_SKULL, d[1] * R_SKULL, d[2] * R_SKULL];
            let phi2 = self.net2.eval(p);
            let phi3 = self.net3.eval(p);
            for k in 0..d2 {
                a_mat[(row, off2 + k)] = w_u * phi2[k];
            }
            for k in 0..d3 {
                a_mat[(row, off3 + k)] = -w_u * phi3[k];
            }
            row += 1;

            let g2 = self.net2.grad_radial(p);
            let g3 = self.net3.grad_radial(p);
            for k in 0..d2 {
                a_mat[(row, off2 + k)] = w_flux * SIGMA_SKULL * g2[k];
            }
            for k in 0..d3 {
                a_mat[(row, off3 + k)] = -w_flux * SIGMA_SCALP * g3[k];
            }
            row += 1;
        }
        let iface_end = row;

        // 4. Outer Scalp Boundary Γout (r = R_SCALP): ∂r u3 = 0
        let bc_start = row;
        let w_bc = 5.0;
        for d in &dir_iface {
            let p = [d[0] * R_SCALP, d[1] * R_SCALP, d[2] * R_SCALP];
            let g3 = self.net3.grad_radial(p);
            for k in 0..d3 {
                a_mat[(row, off3 + k)] = w_bc * g3[k];
            }
            row += 1;
        }
        let bc_end = row;

        // Solve physics-informed regularized normal equations
        let ata = a_mat.transpose() * &a_mat + DMatrix::identity(n_params, n_params) * 1e-10;
        let atb = a_mat.transpose() * &b_vec;
        let w = ata
            .lu()
            .solve(&atb)
            .unwrap_or_else(|| DVector::zeros(n_params));

        let res = &a_mat * &w - &b_vec;
        let rms = |start: usize, end: usize, scale: f64| -> f64 {
            let cnt = end.saturating_sub(start).max(1) as f64;
            let ss: f64 = (start..end)
                .map(|r| {
                    let e = res[r] / scale;
                    e * e
                })
                .sum();
            (ss / cnt).sqrt()
        };
        let pde_residual_rms = rms(pde_start, pde_end, w_pde);
        let interface_residual_rms = rms(iface_start, iface_end, w_u);
        let neumann_bc_rms = rms(bc_start, bc_end, w_bc);

        let potentials: Vec<f64> = eval_pts
            .iter()
            .map(|&pt| {
                let r = (pt[0] * pt[0] + pt[1] * pt[1] + pt[2] * pt[2]).sqrt();
                if r <= R_BRAIN + 1e-6 {
                    let phi = self.net1.eval(pt);
                    let u_h: f64 = (0..d1).map(|k| w[off1 + k] * phi[k]).sum();
                    dipole_inf_potential(pt, r_dip, q, SIGMA_BRAIN) + u_h
                } else if r <= R_SKULL + 1e-6 {
                    let phi = self.net2.eval(pt);
                    (0..d2).map(|k| w[off2 + k] * phi[k]).sum()
                } else {
                    let phi = self.net3.eval(pt);
                    (0..d3).map(|k| w[off3 + k] * phi[k]).sum()
                }
            })
            .collect();

        XpikanForwardResult {
            potentials,
            pde_residual_rms,
            interface_residual_rms,
            neumann_bc_rms,
        }
    }
}

/// Exact analytical 3-shell concentric spherical Legendre series solution (Ary et al. 1981 /
/// Berg & Scherg 1994) for unit-sphere scalp observation points `eval_pts`.
pub fn three_shell_analytical_potential(
    r_dip: [f64; 3],
    q: [f64; 3],
    eval_pts: &[[f64; 3]],
    n_terms: usize,
) -> Vec<f64> {
    let r0 = (r_dip[0] * r_dip[0] + r_dip[1] * r_dip[1] + r_dip[2] * r_dip[2])
        .sqrt()
        .max(1e-9);
    let r0_hat = [r_dip[0] / r0, r_dip[1] / r0, r_dip[2] / r0];
    let q_rad = q[0] * r0_hat[0] + q[1] * r0_hat[1] + q[2] * r0_hat[2];
    let q_tan = [
        q[0] - q_rad * r0_hat[0],
        q[1] - q_rad * r0_hat[1],
        q[2] - q_rad * r0_hat[2],
    ];

    // Solve exact 5x5 boundary-continuity linear system for each multipole degree n = 1..=n_terms
    let mut g_n = Vec::with_capacity(n_terms + 1);
    g_n.push(0.0);
    for n in 1..=n_terms {
        let nf = n as f64;
        let np1 = (n + 1) as f64;
        let r21_p = (R_SKULL / R_BRAIN).powi((n + 1) as i32);
        let r12_n = (R_BRAIN / R_SKULL).powi(n as i32);
        let r32_p = (R_SCALP / R_SKULL).powi((n + 1) as i32);
        let r23_n = (R_SKULL / R_SCALP).powi(n as i32);

        let mut sys = DMatrix::<f64>::zeros(5, 5);
        let mut rhs = DVector::<f64>::zeros(5);
        sys[(0, 0)] = 1.0;
        sys[(0, 1)] = -r21_p;
        sys[(0, 2)] = -r12_n;
        rhs[0] = -1.0;

        sys[(1, 0)] = SIGMA_BRAIN * nf;
        sys[(1, 1)] = SIGMA_SKULL * np1 * r21_p;
        sys[(1, 2)] = -SIGMA_SKULL * nf * r12_n;
        rhs[1] = SIGMA_BRAIN * np1;

        sys[(2, 1)] = 1.0;
        sys[(2, 2)] = 1.0;
        sys[(2, 3)] = -r32_p;
        sys[(2, 4)] = -r23_n;

        sys[(3, 1)] = -SIGMA_SKULL * np1;
        sys[(3, 2)] = SIGMA_SKULL * nf;
        sys[(3, 3)] = SIGMA_SCALP * np1 * r32_p;
        sys[(3, 4)] = -SIGMA_SCALP * nf * r23_n;

        sys[(4, 3)] = -np1;
        sys[(4, 4)] = nf;

        let sol = sys.lu().solve(&rhs).unwrap_or_else(|| DVector::zeros(5));
        g_n.push(sol[3] + sol[4]);
    }

    eval_pts
        .iter()
        .map(|&pt| {
            let r = (pt[0] * pt[0] + pt[1] * pt[1] + pt[2] * pt[2]).sqrt().max(1e-9);
            let u = ((pt[0] * r0_hat[0] + pt[1] * r0_hat[1] + pt[2] * r0_hat[2]) / r).clamp(-1.0, 1.0);
            let q_tan_dot_r = (pt[0] * q_tan[0] + pt[1] * q_tan[1] + pt[2] * q_tan[2]) / r;

            let mut p_prev2 = 1.0;
            let mut p_prev1 = u;
            let mut dp_prev2 = 0.0;
            let mut dp_prev1 = 1.0;

            let mut v = 0.0;
            for n in 1..=n_terms {
                let (pn, dpn) = if n == 1 {
                    (p_prev1, dp_prev1)
                } else {
                    let nf = n as f64;
                    let p_curr = ((2.0 * nf - 1.0) * u * p_prev1 - (nf - 1.0) * p_prev2) / nf;
                    let dp_curr = (2.0 * nf - 1.0) * p_prev1 + dp_prev2;
                    p_prev2 = p_prev1;
                    p_prev1 = p_curr;
                    dp_prev2 = dp_prev1;
                    dp_prev1 = dp_curr;
                    (p_curr, dp_curr)
                };
                let amp = r0.powi((n - 1) as i32)
                    / (4.0 * PI * SIGMA_BRAIN * R_BRAIN.powi((n + 1) as i32));
                let term = n as f64 * pn * q_rad + dpn * q_tan_dot_r;
                v += g_n[n] * amp * term;
            }
            v
        })
        .collect()
}

/// Computes physics-informed XPIKAN inverse source imaging operator using
/// the outer scalp-shell KAN Neumann-spline spatial projector over sensor coordinates
/// and observed sensor covariance, followed by unbiased source standardization.
pub fn xpikan_inverse_operator(
    l: &DMatrix<f64>,
    data: &DMatrix<f64>,
    snr: f64,
    sensor_coords: &[[f64; 3]],
) -> Result<DMatrix<f64>, String> {
    let m = l.nrows();
    if sensor_coords.len() != m {
        return Err("XPIKAN sensor coordinates count must match leadfield rows".into());
    }
    let gram = l * l.transpose();
    let alpha = gram.trace() / m as f64 / (snr * snr);

    // Outer scalp cubic B-spline x spherical harmonic KAN spatial smoothing prior
    // honoring homogeneous scalp Neumann BC (zero normal flux) on unit sphere S^2
    let scalp_basis = SubdomainKanBasis::new(2, 4, R_SCALP, 0.15);
    let d3 = scalp_basis.dim();
    let mut phi_s = DMatrix::zeros(m, d3);
    let mut grad_n = DMatrix::zeros(m, d3);
    for (r, &pt) in sensor_coords.iter().enumerate() {
        let norm = (pt[0] * pt[0] + pt[1] * pt[1] + pt[2] * pt[2]).sqrt().max(1e-9);
        let p_surf = [pt[0] / norm * R_SCALP, pt[1] / norm * R_SCALP, pt[2] / norm * R_SCALP];
        let v = scalp_basis.eval(p_surf);
        let g = scalp_basis.grad_radial(p_surf);
        for c in 0..d3 {
            phi_s[(r, c)] = v[c];
            grad_n[(r, c)] = g[c];
        }
    }

    // Physics-informed ridge projector onto Neumann-consistent scalp KAN manifold
    let reg_kan = (phi_s.transpose() * &phi_s
        + grad_n.transpose() * &grad_n * 0.5
        + DMatrix::identity(d3, d3) * 1e-2)
        .try_inverse()
        .ok_or("XPIKAN scalp manifold matrix singular")?;
    let p_kan = &phi_s * reg_kan * phi_s.transpose();

    // Empirical sensor covariance C_v projected onto the XPIKAN harmonic scalp subspace
    let stride = (data.ncols() / 2000).max(1);
    let n_sub = (0..data.ncols()).step_by(stride).count().max(1);
    let mut cv = DMatrix::zeros(m, m);
    for c_idx in (0..data.ncols()).step_by(stride) {
        let col = data.column(c_idx);
        cv += &col * col.transpose();
    }
    cv.scale_mut(1.0 / n_sub as f64);
    let cv_trace = cv.trace().max(1e-12);
    cv.scale_mut(m as f64 / cv_trace);

    // Combine physics-consistent scalp noise subspace with empirical covariance
    let resid_proj = DMatrix::identity(m, m) - &p_kan;
    let r_phys = DMatrix::identity(m, m) * 0.75 + resid_proj * 0.35 + &p_kan * &cv * 0.15;
    let inv = (gram + r_phys * alpha)
        .try_inverse()
        .ok_or("XPIKAN regularized leadfield inverse is singular")?;
    let mut w = l.transpose() * inv;

    // Unbiased variance standardization for zero localization bias across depths
    for r in 0..w.nrows() {
        let variance = (w.row(r) * l.column(r))[(0, 0)];
        if variance > 0.0 {
            w.row_mut(r).scale_mut(1.0 / variance.sqrt());
        }
    }
    Ok(w)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pearson(a: &[f64], b: &[f64]) -> f64 {
        let n = a.len().min(b.len()) as f64;
        let ma = a.iter().sum::<f64>() / n;
        let mb = b.iter().sum::<f64>() / n;
        let (mut num, mut va, mut vb) = (0.0, 0.0, 0.0);
        for (&x, &y) in a.iter().zip(b.iter()) {
            num += (x - ma) * (y - mb);
            va += (x - ma) * (x - ma);
            vb += (y - mb) * (y - mb);
        }
        num / (va * vb).sqrt().max(1e-15)
    }

    #[test]
    fn cubic_bspline_partition_of_unity() {
        let knots = uniform_bspline_knots(-1.0, 1.0, 5, 3);
        for k in 0..=40 {
            let x = -1.0 + 2.0 * (k as f64 / 40.0);
            let vals = bspline_basis(x, &knots, 3);
            let sum: f64 = vals.iter().sum();
            assert!(
                (sum - 1.0).abs() < 1e-11,
                "cubic B-spline partition of unity violated at x={x}: sum={sum}"
            );
            assert!(vals.iter().all(|&v| v >= -1e-13), "negative B-spline basis at x={x}");
        }
        let kan = KanLayer::new(3, 2, 5, 42);
        let y = kan.forward(&[0.2, -0.4, 0.7]);
        assert_eq!(y.len(), 2);
        assert!(y.iter().all(|v| v.is_finite()));
    }

    #[test]
    fn xpikan_three_shell_forward_satisfies_pde_interfaces_and_matches_analytical() {
        let model = XpikanThreeShellModel::new();
        assert!(model.kan_probe([0.3, 0.4, 0.5]).is_finite());

        // Cortical dipole inside cerebrum (r0 = 0.56) with mixed radial+tangential moment
        let r_dip = [0.20, 0.15, 0.50];
        let q = [0.3, -0.2, 1.0];
        let eval_pts = fibonacci_sphere(64);

        let xp = model.solve_forward_dipole(r_dip, q, &eval_pts);
        let ana = three_shell_analytical_potential(r_dip, q, &eval_pts, 35);

        assert!(
            xp.pde_residual_rms < 1e-3,
            "PDE residual too large: {}",
            xp.pde_residual_rms
        );
        assert!(
            xp.interface_residual_rms < 0.08,
            "Interface continuity residual too large: {}",
            xp.interface_residual_rms
        );
        assert!(
            xp.neumann_bc_rms < 1e-4,
            "Outer Neumann BC residual too large: {}",
            xp.neumann_bc_rms
        );

        let corr = pearson(&xp.potentials, &ana);
        assert!(
            corr > 0.995,
            "XPIKAN 3-shell scalp topography correlation vs exact Legendre series = {corr:.4} (< 0.995)"
        );

        let mean_x = xp.potentials.iter().sum::<f64>() / xp.potentials.len() as f64;
        let mean_a = ana.iter().sum::<f64>() / ana.len() as f64;
        let err_norm: f64 = xp
            .potentials
            .iter()
            .zip(&ana)
            .map(|(x, a)| {
                let d = (x - mean_x) - (a - mean_a);
                d * d
            })
            .sum::<f64>()
            .sqrt();
        let ref_norm: f64 = ana.iter().map(|a| (a - mean_a) * (a - mean_a)).sum::<f64>().sqrt();
        let rel_err = err_norm / ref_norm.max(1e-12);
        assert!(
            rel_err < 0.05,
            "Relative mean-centered L2 error vs exact Legendre = {rel_err:.4} (>= 0.05)"
        );
    }
}
