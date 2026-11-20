import numpy as np, sys
sys.path.insert(0,'/tmp/conn'); import info_ref as I, graph_ref as G
rng=np.random.default_rng(7); fs=250; T=fs*60
n=12; lab=['Fp1','Fp2','F3','F4','C3','C4','P3','P4','O1','O2','T7','T8']
# ground truth: two communities (0-5 frontal/central, 6-11 posterior/temporal) sharing a common source each,
# plus a directed drive from channel 2 (F3) -> channel 8 (O1) with 4-sample delay
sa=rng.standard_normal(T+10); sb=rng.standard_normal(T+10)
x=np.zeros((n,T))
for c in range(n):
    src=sa if c<6 else sb
    x[c]=0.6*src[:T]+rng.standard_normal(T)
x[8]+=0.9*np.roll(x[2],4)          # F3 -> O1, lag 4 samples
gc=I.gcmi_matrix(x); te=I.te_matrix(x,delay=4)
print('GCMI symmetric?',np.allclose(gc,gc.T))
print('TE F3->O1 %.3f   TE O1->F3 %.3f   (asymmetry = direction)'%(te[2,8],te[8,2]))
print('TE max entry is (src,tgt)=',np.unravel_index(np.argmax(te),te.shape),' -> ',lab[np.unravel_index(np.argmax(te),te.shape)[0]],'->',lab[np.unravel_index(np.argmax(te),te.shape)[1]])
nu,gu,wu=G.analyze(gc,False,0.4)
print('GCMI graph (undirected): communities',[int(c) for c in nu['community']],'Q=%.2f'%gu['modularity'])
nd,gd,wd=G.analyze(te,True,0.1)
i=np.argsort(-nd['net_flow'])
print('TE graph (directed): top net-flow (drivers):',[(lab[k],round(nd['net_flow'][k],2)) for k in i[:2]],' sinks:',[(lab[k],round(nd['net_flow'][k],2)) for k in i[-2:]])
print('reciprocity %.2f  (low = one-way flow)'%gd['reciprocity'])
np.save('/tmp/conn/synth_gc.npy',gc); np.save('/tmp/conn/synth_te.npy',te)
