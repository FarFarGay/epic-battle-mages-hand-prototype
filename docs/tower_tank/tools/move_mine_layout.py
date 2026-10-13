"""One-time surgical migration of the authored canyon; preserve unrelated edits."""
from pathlib import Path
import re

path = Path(__file__).resolve().parents[1] / "desert.tscn"
text = path.read_text(encoding="utf-8")
if 'path="res://scenes/deep_mine.tscn"' in text:
    raise SystemExit("Deep mine already installed; edit the saved scenes directly.")
chunks = re.split(r'(?=^\[node )', text, flags=re.M)
prelude = chunks.pop(0)
prelude = re.sub(r'load_steps=(\d+)', lambda m: f'load_steps={int(m[1])+1}', prelude, count=1)
at = prelude.index('[sub_resource ')
prelude = prelude[:at] + '[ext_resource type="PackedScene" path="res://scenes/deep_mine.tscn" id="DeepMine"]\n\n' + prelude[at:]

def translate(block, position):
    line = re.search(r'^transform = Transform3D\(([^\n]+)\)$', block, re.M)
    if line:
        values = line[1].split(',')
        values[-3:] = [str(v) for v in position]
        return block[:line.start()] + 'transform = Transform3D(' + ', '.join(v.strip() for v in values) + ')' + block[line.end():]
    first, rest = block.split('\n', 1)
    return first + '\ntransform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, ' + ', '.join(map(str, position)) + ')\n' + rest

result = []
removed = 0
for block in chunks:
    header = block.split('\n', 1)[0]
    name = re.search(r'name="([^"]+)"', header)[1]
    parent_match = re.search(r'parent="([^"]+)"', header)
    parent = parent_match[1] if parent_match else ''
    full = f'{parent}/{name}'
    if re.match(r'^CanyonLevel/AtollC/Ore\d*(/|$)', full):
        removed += 1
        continue
    if re.match(r'^CanyonLevel/Cliffs/Rock(22|23|63|64|65)(/|$)', full):
        removed += 1
        continue
    if re.match(r'^CanyonLevel/OpenWorld/Rock(11|12)(/|$)', full):
        removed += 1
        continue
    if full == 'CanyonLevel/AtollC':
        block = translate(block, (96, 0, 34))
    if full == './CanyonLevel':
        block = re.sub(r'^WORLD_BOUNDS = .*\n', '', block, flags=re.M)
        block = block.rstrip() + '\nWORLD_BOUNDS = Rect2(-224, -88, 472, 176)\n\n'
    if full == 'CanyonLevel/OpenWorld/Ramp6':
        block = block.replace('parent="CanyonLevel/OpenWorld"', 'parent="CanyonLevel/AtollC"', 1)
        block = translate(block, (-16, 0, -44))
    block = block.replace('parent="CanyonLevel/OpenWorld/Ramp6', 'parent="CanyonLevel/AtollC/Ramp6')
    if parent == 'CanyonLevel/OpenWorld' and name in ['Rock23', 'Rock24', 'Rock25']:
        line = re.search(r'^transform = Transform3D\(([^\n]+)\)$', block, re.M)
        values = [float(v.strip()) for v in line[1].split(',')]
        block = translate(block, (values[-3]-28, values[-2], values[-1]))
    result.append(block)
result.append('[node name="DeepMine" parent="CanyonLevel/AtollC" instance=ExtResource("DeepMine")]\n')
path.write_text(prelude + ''.join(result), encoding='utf-8')
print(f'Moved AtollC, attached northern ramp, removed {removed} obsolete ore/cliff nodes, installed DeepMine.')
