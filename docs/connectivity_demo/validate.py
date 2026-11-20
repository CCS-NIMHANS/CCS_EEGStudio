import numpy as np, networkx as nx, bct, sys
sys.path.insert(0,'/tmp/conn'); import graph_ref as G
rng=np.random.default_rng(3); n=24
# planted 3-community undirected weighted graph
lab=np.repeat([0,1,2],8); P=np.where(lab[:,None]==lab[None,:],.8,.12)
A=(rng.random((n,n))<P)*rng.random((n,n)); A=np.triu(A,1); A=A+A.T
node,g,w=G.analyze(A,False,0.35,1.0,10,1)
print('undirected: n_comm',g['n_communities'],'Q',round(g['modularity'],3),'planted recovered:',
      len(set(zip(lab,node['community'])))==3)
# vs bctpy / networkx on the same thresholded graph
print('clustering  max|diff| vs bct:',np.abs(G.clustering(w,False)-bct.clustering_coef_wu(w)).max().round(10))
print('transitivity diff vs bct   :',abs(G.transitivity(w,False)-bct.transitivity_wu(w)).round(10))
Lm=np.where(w>0,1/np.where(w>0,w,1),0)
print('betweenness  max|diff| vs bct (norm):',np.abs(G.betweenness(np.where(w>0,1/np.where(w>0,w,1),np.inf))-bct.betweenness_wei(Lm)/((n-1)*(n-2))).max().round(10))
Gx=nx.from_numpy_array(w);
for u,v,d in Gx.edges(data=True): d['length']=1/d['weight']
bn=nx.betweenness_centrality(Gx,weight='length',normalized=True)
print('betweenness vs networkx    :',np.abs(np.array([bn[i] for i in range(n)])-node['betweenness']).max().round(10))
ev=nx.eigenvector_centrality_numpy(Gx,weight='weight'); ev=np.array([ev[i] for i in range(n)])
print('eigenvector vs networkx(cos):',round(float(ev@node['eigenvector']/np.linalg.norm(ev)/np.linalg.norm(node['eigenvector'])),6))
print('char path vs bct           :',round(abs(g['char_path_length']-bct.charpath(np.where(w>0,1/np.where(w>0,w,1),0),False,False)[0]),10))
print('assortativity vs bct       :',round(abs(g['assortativity']-bct.assortativity_wei(w,0)),6))
P_,z_=G.participation_and_z(w,[int(c) for c in node['community']])
print('participation vs bct       :',np.abs(P_-bct.participation_coef(w,np.array(node['community'],int)+1)).max().round(8))
print('within-z vs bct            :',np.abs(z_-bct.module_degree_zscore(w,np.array(node['community'],int)+1)).max().round(8))
cl=nx.community.louvain_communities(Gx,weight='weight',seed=1); qx=nx.community.modularity(Gx,cl,weight='weight')
print('Louvain Q ours %.4f  networkx %.4f'%(g['modularity'],qx))
# local efficiency brute force on small graph
print('local eff (self-consistent) mean',node['local_efficiency'].mean().round(4))
# directed: planted directed flow 0..7 -> 8..15
Dm=A.copy()*0;
for i in range(n):
    for j in range(n):
        if i!=j and rng.random()<.25: Dm[i,j]=rng.random()
for i in range(8):
    for j in range(8,16): Dm[i,j]+=1.5*rng.random()
nd,gd,wd=G.analyze(Dm,True,0.3,1.0,10,1)
print('directed: Q',round(gd['modularity'],3),'ncomm',gd['n_communities'],'reciprocity',round(gd['reciprocity'],3))
print(' net_flow sources(0-7) mean %.2f  sinks(8-15) mean %.2f'%(nd['net_flow'][:8].mean(),nd['net_flow'][8:16].mean()))
gdn=nx.from_numpy_array(wd,create_using=nx.DiGraph)
ccx=nx.clustering(gdn,weight='weight');
print(' dir clustering vs bct clustering_coef_wd:',np.abs(G.clustering(wd,True)-bct.clustering_coef_wd(wd)).max().round(8))
print(' dir transitivity-like finite:',np.isfinite(gd['transitivity']))
# determinism
n2,g2,_=G.analyze(A,False,0.35,1.0,10,1); print('deterministic:',np.array_equal(n2['community'],node['community']))
