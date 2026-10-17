import bpy, json, struct, math
from pathlib import Path
from mathutils import Vector
OUT=Path(__file__).resolve().parents[1]
bpy.ops.wm.open_mainfile(filepath=str(OUT/'curb_riot_03.blend'))
expected={'Skateboard','Deck','Grip','FrontTruck','BackTruck','Wheels','Wheel0','Wheel1','Wheel2','Wheel3'}
objects={name:bpy.data.objects[name] for name in expected}
assert objects['Skateboard'].parent is None
assert objects['Wheels'].parent==objects['Skateboard']
for name in ['Deck','Grip','FrontTruck','BackTruck']:assert objects[name].parent==objects['Skateboard']
assert objects['Deck'].location.length<1e-7 and objects['Grip'].location.length<1e-7
wheel_locs=[(-.19,.38,-.105),(.19,.38,-.105),(-.19,-.38,-.105),(.19,-.38,-.105)]
for i,loc in enumerate(wheel_locs):
    ob=objects['Wheel'+str(i)]
    assert ob.parent==objects['Wheels']
    assert (ob.location-Vector(loc)).length<1e-6
    assert abs(ob.dimensions.x-.045)<1e-6
    assert abs(ob.dimensions.y-.11)<1e-6 and abs(ob.dimensions.z-.11)<1e-6
    coords=[v.co for v in ob.data.vertices]
    for ax in range(3):assert abs(min(v[ax] for v in coords)+max(v[ax] for v in coords))<1e-6
assert len({objects['Wheel'+str(i)].data.as_pointer() for i in range(4)})==1
for ob in objects.values():
    assert (ob.scale-Vector((1,1,1))).length<1e-7
    assert max(abs(v) for v in ob.rotation_euler)<1e-7
    assert ob.animation_data is None
    if ob.type=='MESH':
        assert ob.data.uv_layers.active is not None
        assert len(ob.modifiers)==0
deck=objects['Deck']
assert abs(deck.dimensions.x-.34)<.001 and abs(deck.dimensions.y-1.34)<.001
central_bottom=[v.co.z for v in deck.data.vertices if abs(v.co.y)<.25 and v.co.z<0]
assert max(abs(z+.0225) for z in central_bottom)<.002
raw=(OUT/'curb_riot_03.glb').read_bytes()
magic,version,length=struct.unpack_from('<4sII',raw)
assert magic==b'glTF' and version==2 and length==len(raw)
json_length,json_type=struct.unpack_from('<I4s',raw,12)
assert json_type==b'JSON'
g=json.loads(raw[20:20+json_length])
nodes={n['name']:n for n in g['nodes']}
assert set(nodes)==expected, set(nodes)
assert not g.get('animations') and not g.get('skins')
parents={}
for n in g['nodes']:
    for idx in n.get('children',[]):parents[g['nodes'][idx]['name']]=n['name']
for name,ob in objects.items():
    assert parents.get(name)==(ob.parent.name if ob.parent else None)
for i,(x,y,z) in enumerate(wheel_locs):
    n=nodes['Wheel'+str(i)]
    assert max(abs(a-b) for a,b in zip(n['translation'],[x,z,-y]))<1e-6
    assert max(abs(a-b) for a,b in zip(n.get('scale',[1,1,1]),[1,1,1]))<1e-6
    assert n.get('rotation',[0,0,0,1])==[0,0,0,1]
assert len({nodes['Wheel'+str(i)]['mesh'] for i in range(4)})==1
tris=0
for n in g['nodes']:
    if 'mesh' not in n:continue
    for p in g['meshes'][n['mesh']]['primitives']:
        assert all(k in p['attributes'] for k in ['POSITION','NORMAL','TEXCOORD_0'])
        assert 'material' in p
        assert p.get('mode',4)==4
        tris+=g['accessors'][p['indices']]['count']//3
assert all('bufferView' in i for i in g.get('images',[]))
report=json.loads((OUT/'validation.json').read_text())
assert report['triangles']==tris
report['export_checks']={'passed':True,'glb_triangles':tris,'glb_nodes':len(g['nodes']),'glb_meshes':len(g['meshes']),'embedded_images':len(g.get('images',[])),'hierarchy':True,'wheel_centers':True,'wheel_shared_mesh':True,'wheel_dimensions':True,'rotation_scale_applied':True,'uv_normals_materials':True,'no_rig_or_animation':True,'flat_center_bottom':True,'blender_to_gltf_axes':'(x,y,z) -> (x,z,-y)'}
(OUT/'validation.json').write_text(json.dumps(report,indent=2),encoding='utf8')
print('VALIDATION_PASSED',json.dumps(report['export_checks']))
