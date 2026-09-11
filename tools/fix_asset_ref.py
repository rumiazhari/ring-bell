import pathlib
p = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/debug/world_test.gd")
t = p.read_text(encoding='utf-8')
t = t.replace("AssetCatalog.has", "_AC.has")
t = t.replace("AssetCatalog.resolve", "_AC.resolve")
p.write_text(t, encoding='utf-8')
print("replaced")
print(t.count("_AC.has"))
