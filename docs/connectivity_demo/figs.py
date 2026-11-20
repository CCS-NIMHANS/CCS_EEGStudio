import numpy as np, sys, mne, warnings, matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, Circle
warnings.filterwarnings('ignore'); mne.set_log_level('ERROR')
sys.path.insert(0,'/tmp/conn'); import graph_ref as G
d=np.load('/tmp/conn/real.npz'); gc,te,labs=d['gc'],d['te'],list(d['labels']); n=len(labs)
mon=mne.channels.make_standard_montage('standard_1020'); pos3=mon.get_positions()['ch_pos']
P=np.array([[pos3[l][0],pos3[l][1]] for l in labs]); P=P/np.abs(P).max()*0.9
COL=['#3B82F6','#F59E0B','#22C55E','#EF4444','#A855F7','#06B6D4','#EC4899','#84CC16','#F97316','#14B8A6']
BG='#0F172A'
def head(ax):
    ax.add_patch(Circle((0,0),1.0,fill=False,color='#475569',lw=1.5)); ax.plot([-.12,0,.12],[.99,1.12,.99],color='#475569',lw=1.5)
    ax.set_xlim(-1.25,1.25); ax.set_ylim(-1.2,1.3); ax.set_aspect('equal'); ax.axis('off')
def graph_plot(ax,raw,directed,dens,title):
    node,g,w=G.analyze(raw,directed,dens); comm=node['community'].astype(int); head(ax)
    ii,jj=np.nonzero(w); vals=w[ii,jj]
    for i,j,v in sorted(zip(ii,jj,vals),key=lambda t:t[2]):
        if not directed and j>i: continue
        c=COL[comm[i]%10] if comm[i]==comm[j] else '#94A3B8'
        if directed:
            ax.add_patch(FancyArrowPatch(P[i],P[j],connectionstyle='arc3,rad=0.18',arrowstyle='-|>',mutation_scale=9,lw=.6+2.6*v,color=c,alpha=.25+.6*v,shrinkA=6,shrinkB=7))
        else: ax.plot([P[i,0],P[j,0]],[P[i,1],P[j,1]],color=c,lw=.6+3*v,alpha=.2+.6*v)
    s=node['strength']; sz=40+260*s/max(s.max(),1e-9)
    ax.scatter(P[:,0],P[:,1],s=sz,c=[COL[c%10] for c in comm],edgecolors='white',linewidths=.8,zorder=3)
    for k,l in enumerate(labs): ax.text(P[k,0],P[k,1]+.085,l,color='white',fontsize=6.5,ha='center',zorder=4)
    ax.set_title(title+'\nQ=%.2f · %d communities'%(g['modularity'],g['n_communities']),color='white',fontsize=10)
    return node,g,w,comm
def mat_plot(ax,m,comm,title,directed):
    o=np.argsort(comm,kind='stable'); mm=m[np.ix_(o,o)].copy(); np.fill_diagonal(mm,np.nan)
    im=ax.imshow(mm,cmap='viridis'); ax.set_xticks(range(n)); ax.set_yticks(range(n))
    ax.set_xticklabels([labs[k] for k in o],rotation=90,fontsize=5.5,color='white'); ax.set_yticklabels([labs[k] for k in o],fontsize=5.5,color='white')
    for t,k in zip(ax.get_xticklabels(),o): t.set_color(COL[comm[k]%10])
    for t,k in zip(ax.get_yticklabels(),o): t.set_color(COL[comm[k]%10])
    s=0
    for a in range(1,n+1):
        if a==n or comm[o[a]]!=comm[o[s]]:
            ax.add_patch(plt.Rectangle((s-.5,s-.5),a-s,a-s,fill=False,ec=COL[comm[o[s]]%10],lw=2)); s=a
    ax.set_title(title+('\nrows = source → columns = target' if directed else '\nsymmetric'),color='white',fontsize=10); plt.colorbar(im,ax=ax,fraction=.046)
fig,ax=plt.subplots(2,3,figsize=(17,11.5),facecolor=BG)
for a in ax.ravel(): a.set_facecolor(BG)
nodeU,gU,wU,cU=graph_plot(ax[0,1],gc,False,0.2,'GCMI · undirected (scalp graph)')
nodeD,gD,wD,cD=graph_plot(ax[1,1],te,True,0.15,'Transfer entropy · directed (scalp graph)')
mat_plot(ax[0,0],gc,cU,'GCMI matrix, sorted by Louvain community',False)
mat_plot(ax[1,0],te,cD,'Transfer-entropy matrix, sorted by community',True)
# circular (source-level style)
for a,(node,w,c,dir_,tt) in zip([ax[0,2],ax[1,2]],[(nodeU,wU,cU,False,'GCMI · circular (source / ROI-style layout)'),(nodeD,wD,cD,True,'TE · circular, net flow colour')]):
    o=np.lexsort((np.arange(n),c)); ang=-np.pi/2+2*np.pi*np.arange(n)/n; C=np.zeros((n,2)); C[o]=np.c_[np.cos(ang),np.sin(ang)]
    a.set_xlim(-1.5,1.5); a.set_ylim(-1.5,1.5); a.set_aspect('equal'); a.axis('off')
    for i,j in zip(*np.nonzero(w)):
        if not dir_ and j>i: continue
        mid=(C[i]+C[j])/2*.35; col=COL[c[i]%10] if c[i]==c[j] else '#94A3B8'
        if dir_: a.add_patch(FancyArrowPatch(C[i],C[j],connectionstyle='arc3,rad=0.3',arrowstyle='-|>',mutation_scale=8,lw=.5+2.4*w[i,j],color=col,alpha=.2+.6*w[i,j],shrinkA=5,shrinkB=6))
        else:
            t=np.linspace(0,1,30)[:,None]; pts=(1-t)**2*C[i]+2*t*(1-t)*mid+t**2*C[j]; a.plot(pts[:,0],pts[:,1],color=col,lw=.5+2.8*w[i,j],alpha=.2+.6*w[i,j])
    nf=node['net_flow'] if dir_ else None
    colors=[plt.cm.coolwarm((nf[k]+1)/2) for k in range(n)] if dir_ else [COL[k%10] for k in c]
    a.scatter(C[:,0],C[:,1],s=90,c=colors,edgecolors=[COL[k%10] for k in c],linewidths=1.8,zorder=3)
    for k,l in enumerate(labs): a.text(C[k,0]*1.14,C[k,1]*1.14,l,color='white',fontsize=6.5,ha='center',va='center')
    a.set_title(tt,color='white',fontsize=10)
fig.suptitle('Connectivity outputs · Workshop_Test (26 good channels, 9 clean 4-s epochs)   ·   outline = Louvain community',color='white',fontsize=12)
plt.tight_layout(rect=[0,0,1,.97]); plt.savefig('/tmp/conn/connectivity_demo.png',dpi=110,facecolor=BG)
print('saved')
