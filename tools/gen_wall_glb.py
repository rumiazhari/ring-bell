import struct, json, pathlib

out_path = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/art/modules/wall_2m.glb")
out_path.parent.mkdir(parents=True, exist_ok=True)

# Wall size: 2.0 x 2.05 x 0.18 (hx=1.0, hy=1.025, hz=0.09) centered at origin
hx, hy, hz = 1.0, 1.025, 0.09
positions = [
    (-hx, -hy, -hz), (hx, -hy, -hz), (hx, -hy, hz), (-hx, -hy, hz),
    (-hx, hy, -hz), (hx, hy, -hz), (hx, hy, hz), (-hx, hy, hz),
]
indices = [
    0,1,2, 0,2,3,  # bottom
    4,7,6, 4,6,5,  # top
    0,4,5, 0,5,1,  # front (-Z)
    2,6,7, 2,7,3,  # back (+Z)
    1,5,6, 1,6,2,  # right (+X)
    3,7,4, 3,4,0,  # left (-X)
]

# Pack buffer: positions as float32 LE, indices as uint16 LE
buf = struct.pack('<' + 'f'* (len(positions)*3), *[c for v in positions for c in v])
buf += struct.pack('<' + 'H'* len(indices), *indices)
# Ensure 4-byte alignment (already)
assert len(buf) % 4 == 0
byteLength = len(buf)

# JSON descriptor
json_dict = {
    "asset": {"version":"2.0", "generator":"RingBell wall_2m placeholder"},
    "scene": 0,
    "scenes": [{"nodes":[0]}],
    "nodes": [{"mesh":0, "name":"Wall2m"}],
    "meshes": [{"name":"Wall2mMesh", "primitives":[{"attributes":{"POSITION":0}, "indices":1, "material":0}]}],
    "materials": [{"name":"WallMaterial", "pbrMetallicRoughness":{"baseColorFactor":[0.66,0.63,0.56,1.0]}, "doubleSided": True}],
    "accessors": [
        {"bufferView":0, "componentType":5126, "count":8, "type":"VEC3", "max":[hx, hy, hz], "min":[-hx, -hy, -hz]},
        {"bufferView":1, "componentType":5123, "count":36, "type":"SCALAR"}
    ],
    "bufferViews": [
        {"buffer":0, "byteOffset":0, "byteLength":96, "target":34962},
        {"buffer":0, "byteOffset":96, "byteLength":72, "target":34963}
    ],
    "buffers": [{"byteLength": byteLength}]
}
json_bytes = json.dumps(json_dict, separators=(',',':')).encode('utf-8')
# pad JSON to 4-byte with spaces (0x20)
pad_len = (4 - (len(json_bytes) % 4)) % 4
json_bytes += b' ' * pad_len
json_chunk_len = len(json_bytes)
# pad BIN to 4-byte (already)
bin_chunk_len = len(buf)

total_len = 12 + 8 + json_chunk_len + 8 + bin_chunk_len
# Header: magic 'glTF' 0x46546C67 LE, version 2, length
header = struct.pack('<4sII', b'glTF', 2, total_len)
# Chunks: JSON chunk header: length, type 'JSON' 0x4E4F534A, data; BIN chunk: length, type 'BIN\0' 0x004E4942
json_header = struct.pack('<I4s', json_chunk_len, b'JSON')
bin_header = struct.pack('<I4s', bin_chunk_len, b'BIN\x00')

with open(out_path, 'wb') as f:
    f.write(header)
    f.write(json_header)
    f.write(json_bytes)
    f.write(bin_header)
    f.write(buf)

print(f"Wrote {out_path} len={total_len} json={json_chunk_len} bin={bin_chunk_len}")
# Also create a placeholder gltf for reference
gltf_path = out_path.with_suffix('.gltf')
# For gltf, need to embed buffer as base64? Instead just write json with uri placeholder not needed for test, just copy json dict to file
import base64, json as js
b64 = base64.b64encode(buf).decode('ascii')
json_dict_gltf = dict(json_dict)
json_dict_gltf["buffers"] = [{"byteLength": byteLength, "uri": "data:application/octet-stream;base64," + b64}]
with open(gltf_path, 'w', encoding='utf-8') as fg:
    js.dump(json_dict_gltf, fg, indent=2)
print(f"Wrote {gltf_path}")

# Also ensure wall_2m_placeholder.gltf exists as fallback stub reference
placeholder_path = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/art/modules/wall_2m_placeholder.gltf")
if not placeholder_path.exists():
    with open(placeholder_path, 'w', encoding='utf-8') as fp:
        js.dump(json_dict_gltf, fp, indent=2)
    print(f"Wrote placeholder {placeholder_path}")
