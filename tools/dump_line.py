import pathlib
p = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/debug/world_test.gd")
lines = p.read_text(encoding='utf-8').splitlines()
for idx in [238,239,240]:  # 0-indexed, line 239 is idx 238
    if 0 <= idx < len(lines):
        line = lines[idx]
        print(f"Line {idx+1}: {repr(line)}")
        # hex
        print("".join(f"{ord(c):02x} " for c in line[:60]))
