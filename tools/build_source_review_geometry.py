"""Build transparent orthogonal atlas outlines from local FreeSurfer pial/aparc data.

No downloads or synthetic anatomy. Coordinates are FreeSurfer surface RAS mm.
Usage: python3 tools/build_source_review_geometry.py SUBJECT_DIRECTORY OUTPUT_JSON
"""
import sys,struct,json,pathlib
import numpy as np
from scipy.spatial import ConvexHull

def i32(f): return struct.unpack('>i',f.read(4))[0]
def surface(path):
    with open(path,'rb') as f:
        assert int.from_bytes(f.read(3),'big')==16777214
        f.readline();f.readline();nv,nf=i32(f),i32(f)
        xyz=np.frombuffer(f.read(nv*12),dtype='>f4').astype(float).reshape(-1,3)
        faces=np.frombuffer(f.read(nf*12),dtype='>i4').astype(int).reshape(-1,3)
    return xyz,faces

def annotation(path):
    with open(path,'rb') as f:
        n=i32(f); pairs=np.frombuffer(f.read(n*8),dtype='>i4').reshape(n,2);labels=pairs[:,1]
        assert i32(f)==1
        count=i32(f); assert count == -2, 'Only annotation version 2 supported'
        _=i32(f);f.read(i32(f));entries=i32(f);table={}
        for _ in range(entries):
            index=i32(f);name=f.read(i32(f)).rstrip(b'\0').decode();rgba=[i32(f) for _ in range(4)]
            table[name]=(rgba[0]+256*rgba[1]+65536*rgba[2],rgba[:3])
    return labels,table

def paths_from_segments(segments):
    # Join 3-D triangle intersections before projection; each point has degree two.
    coords={};links={}
    for a,b in segments:
        ka=tuple(np.round(a,3));kb=tuple(np.round(b,3))
        if ka==kb:continue
        coords[ka]=a;coords[kb]=b;links.setdefault(ka,set()).add(kb);links.setdefault(kb,set()).add(ka)
    result=[]
    while links:
        start=next(iter(links));cur=start;path=[coords[cur]]
        while cur in links and links[cur]:
            nxt=next(iter(links[cur]));links[cur].remove(nxt)
            if not links[cur]:del links[cur]
            if nxt in links:
                links[nxt].discard(cur)
                if not links[nxt]:del links[nxt]
            path.append(coords[nxt]);cur=nxt
            if cur==start:break
        if len(path)>2:result.append(np.asarray(path))
    return result

def simplify(points,tol=.45):
    if len(points)<4:return points
    delta=points[-1]-points[0];den=float(delta@delta)
    if den<1e-9:dist=np.linalg.norm(points-points[0],axis=1)
    else:
        t=np.clip(((points-points[0])@delta)/den,0,1);dist=np.linalg.norm(points-points[0]-t[:,None]*delta,axis=1)
    k=int(np.argmax(dist))
    if dist[k]<=tol:return points[[0,-1]]
    return np.r_[simplify(points[:k+1]),simplify(points[k:])[1:]]

def projections(p):return [np.c_[-p[:,1],p[:,2]],p[:,[0,2]],p[:,[0,1]]]

def build(subject, output):
    names=set(json.loads(pathlib.Path('assets/source_regions.json').read_text()));rois=[];all_xyz=[]
    for hemi in ['lh','rh']:
        xyz,faces=surface(subject/'surf'/f'{hemi}.pial');labels,table=annotation(subject/'label'/f'{hemi}.aparc.annot');all_xyz.append(xyz)
        triangles=xyz[faces]
        for region,(rgbkey,rgb) in table.items():
            name=f'{region}-{hemi}'
            if name not in names:continue
            mask=labels==rgbkey;flags=mask[faces];cross=(flags.sum(axis=1)>0)&(flags.sum(axis=1)<3)
            tri=triangles[cross];m=flags[cross];segments=[]
            for t,marked in zip(tri,m):
                points=[(t[a]+t[b])/2 for a,b in [(0,1),(1,2),(2,0)] if marked[a]!=marked[b]]
                if len(points)==2:segments.append(points)
            lines=paths_from_segments(segments)
            projected=[]
            for view in range(3):
                projected.append([np.round(simplify(projections(line)[view]),2).tolist() for line in lines])
            center=xyz[mask].mean(axis=0)
            rois.append(dict(name=name,color=rgb,centers=[p[0].round(2).tolist() for p in projections(center[None,:])],outlines=projected))
    all_xyz=np.concatenate(all_xyz);shells=[]
    for p in projections(all_xyz):
        hull=ConvexHull(p);shell=p[hull.vertices];shell=np.r_[shell,shell[:1]];shells.append(np.round(shell,2).tolist())
    assert {r['name'] for r in rois}==names
    data=dict(schema='source-review-geometry-v1',template='FreeSurfer fsaverage pial / aparc (Desikan–Killiany)',coordinates='surface RAS mm',
      note='Orthogonal transparent template projections; ROI boundaries are projected cortical boundaries, not subject-specific anatomy or voxel activation maps.',views=['Sagittal','Coronal','Axial'],shells=shells,regions=rois)
    output.write_text(json.dumps(data,separators=(',',':')))
    print(len(rois),'regions;',output.stat().st_size,'bytes')
if __name__=='__main__': build(pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]))
