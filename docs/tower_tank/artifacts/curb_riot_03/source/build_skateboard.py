import bpy, math, json, os, sys, random
from pathlib import Path
from mathutils import Vector
import numpy as np

OUT = Path(__file__).resolve().parents[1]
TEX = OUT / 'textures'
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
for datablock in list(bpy.data.materials): bpy.data.materials.remove(datablock)
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'
scene.unit_settings.scale_length = 1.0
scene.render.engine = 'CYCLES'
scene.cycles.samples = 32
scene.cycles.use_denoising = True
scene.world.color = (0.24, 0.24, 0.24)
random.seed(37)
rng = np.random.default_rng(37)

def image_array(name, rgb, gray=False, linear_input=False):
    a = np.asarray(rgb, dtype=np.float32)
    if a.ndim == 2: a = np.repeat(a[:,:,None],3,axis=2)
    if not gray and not linear_input:
        a = np.where(a <= .04045, a/12.92, ((a+.055)/1.055)**2.4)
    a = np.repeat(np.repeat(a, 2048//a.shape[0], 0), 2048//a.shape[1], 1)
    rgba = np.ones((a.shape[0],a.shape[1],4),np.float32)
    rgba[:,:,:3] = np.clip(a,0,1)
    im = bpy.data.images.new(name, width=a.shape[1], height=a.shape[0], alpha=False)
    if gray: im.colorspace_settings.name='Non-Color'
    im.pixels.foreach_set(rgba.ravel())
    im.filepath_raw = str(TEX/(name+'.png')); im.file_format='PNG'; im.save()
    return im

art = bpy.data.images.load(str(OUT/'source/deck_art_original.png'))
art.name='Deck_Bottom_BaseColor'; art.scale(2048,2048)
art.filepath_raw=str(TEX/'Deck_Bottom_BaseColor.png'); art.file_format='PNG'; art.save()
n=256
noise=rng.uniform(-.022,.022,(n,64,1))
grip=np.ones((n,64,3))*[.105,.112,.113]+noise
yy,xx=np.mgrid[0:n,0:64]
# Thin diagonal red stripe near the tail, with cream worn edges.
stripe=np.abs(yy-(.50*xx+16))
grip[stripe<7]=[.65,.53,.34]
grip[stripe<5]=[.53,.075,.06]
for cx,cy,rx,ry in [(5,200,4,8),(57,148,6,10),(4,73,4,11),(60,15,4,7)]:
    mask=((xx-cx)/rx)**2+((yy-cy)/ry)**2 < rng.uniform(.2,1.2,(n,64))
    grip[mask]=np.clip(np.array([.42,.43,.42])+noise[mask],0,1)
grip_img=image_array('Grip_BaseColor',grip)
wood=np.ones((n,n,3))*[.49,.285,.12]+rng.uniform(-.035,.035,(n,n,1))
for y in range(n): wood[y]*= .74 if y%37<5 else 1.0
wood_img=image_array('Maple_Edge_BaseColor',wood,linear_input=True)
metal_img=image_array('Truck_BaseColor',np.ones((n,n,3))*[.34,.37,.40]+rng.uniform(-.045,.045,(n,n,1)),linear_input=True)
wheel_img=image_array('Wheel_BaseColor',np.ones((n,n,3))*[.66,.47,.10]+rng.uniform(-.035,.035,(n,n,1)),linear_input=True)
rough_img=image_array('Paint_Roughness',rng.uniform(.68,.85,(n,n)),True)
grip_rough=image_array('Grip_Roughness',rng.uniform(.88,.99,(n,n)),True)
metal_rough=image_array('Truck_Roughness',rng.uniform(.30,.46,(n,n)),True)
wheel_rough=image_array('Wheel_Roughness',rng.uniform(.54,.72,(n,n)),True)

def mat(name, color, rough=.6, metallic=0, image=None, rimage=None):
    m=bpy.data.materials.new(name); m.use_nodes=True
    m.diffuse_color=(*color,1)
    p=m.node_tree.nodes.get('Principled BSDF')
    p.inputs['Base Color'].default_value=(*color,1)
    p.inputs['Roughness'].default_value=rough
    p.inputs['Metallic'].default_value=metallic
    for im,slot in [(image,'Base Color'),(rimage,'Roughness')]:
        if im:
            t=m.node_tree.nodes.new('ShaderNodeTexImage'); t.image=im; t.interpolation='Closest'
            m.node_tree.links.new(t.outputs['Color'],p.inputs[slot])
    return m

woodmat=mat('Maple | laminated edge',(.49,.285,.12),image=wood_img,rimage=rough_img)
printmat=mat('CURB RIOT | underside',(.8,.7,.5),image=art,rimage=rough_img)
gripmat=mat('Grip | charcoal + tail slash',(.1,.1,.1),image=grip_img,rimage=grip_rough)
steel=mat('Cast aluminum',(.34,.37,.4),metallic=.72,image=metal_img,rimage=metal_rough)
dark=mat('Dark steel',(.018,.023,.027),.42,.7)
silver=mat('Bolt steel',(.48,.52,.56),.28,.85)
rubber=mat('Oxide red bushings',(.14,.012,.008),.67)
gold=mat('Mustard urethane',(.66,.47,.10),image=wheel_img,rimage=wheel_rough)

def empty(name,parent=None):
    ob=bpy.data.objects.new(name,None); scene.collection.objects.link(ob); ob.parent=parent
    ob.empty_display_type='PLAIN_AXES'; ob.empty_display_size=.08
    return ob
root=empty('Skateboard'); wheels=empty('Wheels',root)
root['asset']='CURB RIOT / 03'; root['units']='meters'; root['forward']='+Y'; root['up']='+Z'

def mesh_obj(name,verts,faces,mats,indices=None,uvs=None):
    me=bpy.data.meshes.new(name+'Mesh'); me.from_pydata(verts,[],faces); me.update()
    ob=bpy.data.objects.new(name,me); scene.collection.objects.link(ob)
    for m in mats: me.materials.append(m)
    uv=me.uv_layers.new(name='UVMap')
    for p in me.polygons:
        p.material_index=indices[p.index] if indices else 0
        for li in p.loop_indices:
            v=me.vertices[me.loops[li].vertex_index].co
            uv.data[li].uv=uvs[p.index][li-p.loop_start] if uvs else (v.x/.34+.5,v.y/1.34+.5)
    return ob

def halfwidth(y):
    if abs(y)<=.50: return .17
    q=(abs(y)-.50)/.17
    return .17*math.sqrt(max(0,1-q*q))
def lift(y):
    t=max(0,(abs(y)-.43)/.24)
    return .072*t*t*(1.12 if y>0 else 1)
def top_z(x,y): return .0225+lift(y)+.006*(x/.17)**2

# Tip endpoints have a short straight facet, matching the low-poly concept.
ys=[-.67,-.665,-.65,-.625,-.59,-.55,-.50]+[i*.025 for i in range(-19,20)]+[.50,.55,.59,.625,.65,.665,.67]
xs=[-1,-.75,-.5,-.25,0,.25,.5,.75,1]
verts=[]; faces=[]; mids=[]; uvs=[]
for upper in [False,True]:
    for y in ys:
        w=max(.015,halfwidth(y))
        for t in xs:
            x=w*t
            verts.append((x,y,top_z(x,y) if upper else -.0225+lift(y)))
rows=len(ys); cols=len(xs); side=rows*cols
def uv_print(v,upper):
    x,y,z=v
    # Keep the central skull compact while extending lightning into both kicks.
    if y < -.23: v=.18*(y+.67)/.44
    elif y>.23: v=.82+.18*(y-.23)/.44
    else: v=.18+.64*(y+.23)/.46
    return (x/.34+.5, y/1.34+.5) if upper else (.5-x/.34,v)
for upper in [False,True]:
    offset=side if upper else 0
    for j in range(rows-1):
        for i in range(cols-1):
            f=[offset+j*cols+i,offset+j*cols+i+1,offset+(j+1)*cols+i+1,offset+(j+1)*cols+i]
            if not upper:f.reverse()
            faces.append(f); mids.append(0 if upper else 1);uvs.append([uv_print(verts[k],upper) for k in f])
boundary=list(range(cols))+[j*cols+cols-1 for j in range(1,rows)]+[(rows-1)*cols+i for i in range(cols-2,-1,-1)]+[j*cols for j in range(rows-2,0,-1)]
for i,a in enumerate(boundary):
    b=boundary[(i+1)%len(boundary)]
    faces.append([a,b,b+side,a+side]); mids.append(0)
    uvs.append([(i/len(boundary),0),((i+1)/len(boundary),0),((i+1)/len(boundary),1),(i/len(boundary),1)])
deck=mesh_obj('Deck',verts,faces,[woodmat,printmat],mids,uvs); deck.parent=root

def bevel(ob,width,segments=1):
    bpy.context.view_layer.objects.active=ob
    mod=ob.modifiers.new('Small edge bevel','BEVEL');mod.width=width;mod.segments=segments
    mod.affect='EDGES'; mod.angle_limit=.4
    bpy.ops.object.modifier_apply(modifier=mod.name)
bevel(deck,.0018,1)

gv=[];gf=[]
for y in ys:
    gy=y*.985
    for t in xs:
        x=t*max(.013,halfwidth(y))*.965
        gv.append((x,gy,top_z(x,gy)+.0009))
for j in range(rows-1):
    for i in range(cols-1):
        a=j*cols+i;gf.append([a,a+1,a+cols+1,a+cols])
grip=mesh_obj('Grip',gv,gf,[gripmat]);grip.parent=root

def cube(name,loc,scale,material,bevelwidth=0):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc)
    ob=bpy.context.object;ob.name=name;ob.dimensions=scale
    bpy.ops.object.transform_apply(location=False,rotation=True,scale=True)
    ob.data.materials.append(material)
    if bevelwidth:bevel(ob,bevelwidth)
    return ob
def cyl(name,loc,r,depth,material,vertices=12,axis='Z'):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices,radius=r,depth=depth,location=loc)
    ob=bpy.context.object;ob.name=name
    if axis=='X':ob.rotation_euler[1]=math.pi/2
    ob.data.materials.append(material)
    bpy.ops.object.transform_apply(location=False,rotation=True,scale=True)
    return ob
def join(parts,name,origin,parent):
    bpy.ops.object.select_all(action='DESELECT')
    for ob in parts:ob.select_set(True)
    bpy.context.view_layer.objects.active=parts[0];bpy.ops.object.join()
    ob=parts[0];ob.name=name
    scene.cursor.location=origin;bpy.ops.object.origin_set(type='ORIGIN_CURSOR')
    ob.parent=parent;return ob

deckparts=[deck]
for front in [True,False]:
    y=.38 if front else -.38;s=1 if front else -1
    pieces=[cube('Mount plate',(0,y,-.032),(.13,.145,.017),dark,.004)]
    pieces.append(cube('Plate bevel',(0,y,-.042),(.112,.126,.008),steel,.003))
    for x in [-.045,.045]:
        for dy in [-.05,.05]:
            pieces.append(cyl('Mount nut',(x,y+dy,-.05),.010,.010,silver,6))
            bolt=cyl('Deck bolt',(x,y+dy,top_z(x,y+dy)+.002),.008,.0025,dark,8)
            deckparts.append(bolt)
            deckparts.append(cube('Bolt slot',(x,y+dy,top_z(x,y+dy)+.0035),(.007,.0018,.0008),silver))
    pieces.append(cube('Pivot block',(0,y+s*.035,-.068),(.055,.055,.058),steel,.008))
    pieces.append(cyl('Red bushing',(0,y-s*.028,-.079),.026,.036,rubber))
    pieces.append(cyl('Bushing washer',(0,y-s*.028,-.099),.028,.005,dark))
    pieces.append(cyl('Kingpin nut',(0,y-s*.028,-.106),.016,.013,silver,6))
    pieces.append(cyl('Axle',(0,y,-.105),.009,.410,silver,12,'X'))
    # Cast hanger tapers toward axle tips.
    hv=[]
    for x,r in [(-.168,.012),(-.12,.018),(0,.025),(.12,.018),(.168,.012)]:
        for j in range(8):
            a=2*math.pi*j/8;hv.append((x,y+r*math.cos(a),-.105+r*math.sin(a)))
    hf=[]
    for k in range(4):
        for j in range(8):hf.append([k*8+j,k*8+(j+1)%8,(k+1)*8+(j+1)%8,(k+1)*8+j])
    hf.extend([list(range(7,-1,-1)),list(range(32,40))])
    pieces.append(mesh_obj('Hanger',hv,hf,[steel]))
    truck=join(pieces,'FrontTruck' if front else 'BackTruck',(0,y,-.105),root)
join(deckparts,'Deck',(0,0,0),root)

# Lathed wheel mesh: axis X, centered exactly at its bearing. Radius .055; width .045.
profile=[(-.0225,.014),(-.0225,.026),(-.0225,.047),(-.016,.055),(.016,.055),(.0225,.047),(.0225,.026),(.0225,.014),(.016,.009),(-.016,.009)]
wv=[];wf=[];wi=[];wu=[];segs=16
for x,r in profile:
    for j in range(segs):
        a=2*math.pi*j/segs;wv.append((x,r*math.cos(a),r*math.sin(a)))
for k in range(len(profile)):
    nk=(k+1)%len(profile)
    for j in range(segs):
        nj=(j+1)%segs
        wf.append([k*segs+j,k*segs+nj,nk*segs+nj,nk*segs+j])
        wi.append(1 if k in [0,6] else (2 if k in [7,8,9] else 0))
        wu.append([(j/segs,k/len(profile)),((j+1)/segs,k/len(profile)),((j+1)/segs,(k+1)/len(profile)),(j/segs,(k+1)/len(profile))])
wheel=mesh_obj('Wheel0',wv,wf,[gold,rubber,silver],wi,wu)
for i,loc in enumerate([(-.19,.38,-.105),(.19,.38,-.105),(-.19,-.38,-.105),(.19,-.38,-.105)]):
    ob=wheel if i==0 else bpy.data.objects.new('Wheel'+str(i),wheel.data)
    if i:scene.collection.objects.link(ob)
    ob.location=loc;ob.parent=wheels;ob['rotation_axis']='X'

# Correct winding consistently and validate the export asset before adding a presentation scene.
asset=[root,wheels]+[o for o in scene.objects if o.type=='MESH']
import bmesh
for ob in asset:
    if ob.type!='MESH':continue
    bm=bmesh.new();bm.from_mesh(ob.data);bmesh.ops.recalc_face_normals(bm,faces=bm.faces);bm.to_mesh(ob.data);bm.free()
    for poly in ob.data.polygons:poly.use_smooth=False
    ob.data.calc_loop_triangles()
assert set(o.name for o in asset)=={'Skateboard','Wheels','Deck','Grip','FrontTruck','BackTruck','Wheel0','Wheel1','Wheel2','Wheel3'}
for ob in asset:
    assert max(abs(x-1) for x in ob.scale)<1e-6
    assert max(abs(x) for x in ob.rotation_euler)<1e-6
triangles=sum(len(o.data.loop_triangles) for o in asset if o.type=='MESH')
report={'triangles':triangles,'blender_version':bpy.app.version_string,'objects':{},'dimensions_m':{'deck_length':1.34,'deck_width':.34,'center_wood_thickness':.045,'wheel_diameter':.11,'wheel_width':.045},'export_yup':True}
for ob in asset:
    report['objects'][ob.name]={'parent':ob.parent.name if ob.parent else None,'location':list(ob.location),'rotation':list(ob.rotation_euler),'scale':list(ob.scale),'triangles':len(ob.data.loop_triangles) if ob.type=='MESH' else 0}
(OUT/'validation.json').write_text(json.dumps(report,indent=2),encoding='utf8')
bpy.ops.object.select_all(action='DESELECT')
for ob in asset:ob.select_set(True)
bpy.context.view_layer.objects.active=bpy.data.objects['Deck']
bpy.ops.export_scene.gltf(filepath=str(OUT/'curb_riot_03.glb'),export_format='GLB',use_selection=True,export_yup=True,export_apply=True,export_texcoords=True,export_normals=True,export_materials='EXPORT',export_animations=False,export_extras=True)

# Cameras and lights belong to a separate non-exported collection.
studio=bpy.data.collections.new('STUDIO | excluded from GLB');scene.collection.children.link(studio)
def studio_link(ob):
    for c in list(ob.users_collection):c.objects.unlink(ob)
    studio.objects.link(ob)
def aim(ob,target=(0,0,0)):ob.rotation_euler=(Vector(target)-ob.location).to_track_quat('-Z','Y').to_euler()
def area(name,loc,power,size):
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.shape='DISK';data.size=size
    ob=bpy.data.objects.new(name,data);studio.objects.link(ob);ob.location=loc;aim(ob)
area('Softbox',(-1.5,-.5,-2),130,2.5)
area('Rim',(1,1,-1.5),90,1.8)
area('Top fill',(0,0,2),150,2)
bpy.ops.object.camera_add(location=(1.05,-1.7,-1.6));cam=bpy.context.object;cam.name='Preview Camera';studio_link(cam);aim(cam)
cam.data.type='ORTHO';cam.data.ortho_scale=1.63;scene.camera=cam
scene.render.resolution_x=1400;scene.render.resolution_y=1400;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.render.film_transparent=True
scene.view_settings.view_transform='AgX'
scene.view_settings.look='AgX - Medium High Contrast'
scene.render.filepath=str(OUT/'preview_bottom.png')
for area_ui in bpy.context.screen.areas:
    if area_ui.type=='VIEW_3D':
        area_ui.spaces.active.region_3d.view_distance=1.8
        area_ui.spaces.active.region_3d.view_rotation=cam.rotation_euler.to_quaternion()
        area_ui.spaces.active.region_3d.view_location=(0,0,0)
        area_ui.spaces.active.shading.type='MATERIAL'
scene.cursor.location=(0,0,0)
bpy.ops.object.select_all(action='DESELECT')
bpy.context.view_layer.objects.active=bpy.data.objects['Deck']
bpy.data.objects['Deck'].select_set(True)
for im in bpy.data.images:
    if im.source=='FILE':
        im.filepath=str(TEX/Path(im.filepath).name)
        im.pack()
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'curb_riot_03.blend'))
bpy.ops.render.render(write_still=True)
cam.location=(0,0,2);aim(cam);cam.rotation_euler=(0,0,0)
scene.render.filepath=str(OUT/'preview_top.png');bpy.ops.render.render(write_still=True)
cam.location=(2,0,0);aim(cam);scene.render.filepath=str(OUT/'preview_side.png');bpy.ops.render.render(write_still=True)
print('ASSET_COMPLETE',json.dumps(report))
