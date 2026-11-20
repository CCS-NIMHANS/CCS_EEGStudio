import numpy as np, mne, sys, glob, warnings
warnings.filterwarnings('ignore'); mne.set_log_level('ERROR')
sys.path.insert(0,'/tmp/conn'); import info_ref as I, graph_ref as G
f=glob.glob('/root/mnt/Workshop_Test/*_clean.edf')+glob.glob(__import__('os').path.expanduser('~/mnt/Workshop_Test/*_clean.edf'))
raw=mne.io.read_raw_edf(f[0],preload=True); print(f[0].split('/')[-1],len(raw.ch_names),'ch',raw.info['sfreq'],'Hz',round(raw.times[-1]),'s')
raw.pick('eeg');
bad=[c for c in ['FT10','TP10','F3','T7','P3','FC2'] if c in raw.ch_names]; raw.drop_channels(bad)
raw.filter(1,40,verbose=False); raw.set_eeg_reference('average',verbose=False)
d=raw.get_data()*1e6; fs=raw.info['sfreq']; labs=raw.ch_names; n=len(labs)
L=int(4*fs); starts=np.arange(int(20*fs),int(20*fs)+L*12,L)   # 12 epochs of 4 s (20-68 s)
gc=np.zeros((n,n)); te=np.zeros((n,n)); k=0
for s in starts:
    seg=d[:,s:s+L]
    if np.abs(seg).max()>150: continue
    gc+=I.gcmi_matrix(seg); te+=I.te_matrix(seg,delay=2); k+=1
gc/=k; te/=k; print('epochs used',k,'channels',n)
np.savez('/tmp/conn/real.npz',gc=gc,te=te,labels=np.array(labs))
nu,gu,wu=G.analyze(gc,False,0.2); nd,gd,wd=G.analyze(te,True,0.15)
print('GCMI undirected: Q=%.2f communities=%d  char path %.2f  clustering %.2f'%(gu['modularity'],gu['n_communities'],gu['char_path_length'],gu['mean_clustering']))
print('  communities:',{int(c):[labs[i] for i in range(n) if nu['community'][i]==c] for c in sorted(set(nu['community']))})
print('TE directed: Q=%.2f communities=%d reciprocity %.2f'%(gd['modularity'],gd['n_communities'],gd['reciprocity']))
o=np.argsort(-nd['net_flow']); print('  top drivers',[(labs[i],round(nd['net_flow'][i],2)) for i in o[:4]],' top sinks',[(labs[i],round(nd['net_flow'][i],2)) for i in o[-4:]])
print('  TE asymmetry: mean|TE_ij - TE_ji| / mean TE = %.2f ; GCMI asymmetry = %.2f'%(np.abs(te-te.T).mean()/te.mean(),np.abs(gc-gc.T).mean()))
