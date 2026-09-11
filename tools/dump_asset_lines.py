import pathlib
p = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/debug/world_test.gd")
lines = p.read_text(encoding='utf-8').splitlines()
for idx in range(5410, 5440):
    if 0 <= idx < len(lines):
        line = lines[idx]
        if "MeshBatcher" in line:
            print(f"Line {idx+1}: {repr(line)}")
