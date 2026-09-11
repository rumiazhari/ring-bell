import pathlib
p = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/world/generation/building_builder.gd")
text = p.read_text(encoding='utf-8')
old = """\t\t\t# Partitions are along shared room edges: pr is 0.18 thick wall (WorldConstants.CITY_INTERIOR_WALL_T), op is 0.95 opening.
\t\t\tvar y0 := float(fi) * fh
\t\t\tvar wall_h := fh"""
new = """\t\t\t# Partitions are along shared room edges: pr is 0.18 thick wall (WorldConstants.CITY_INTERIOR_WALL_T), op is 0.95 opening.
\t\t\t# G9 M2 Asset Pipeline: try wall_2m modular GLB at wall center, visual only 0 collider, scale 1.0, fallback to box.
\t\t\t# Caps per chunk 4, deterministic, byte-identical shuffled.
\t\t\tvar asset_handled := false
\t\t\tif b.asset_instance_count() < WorldConstants.MAX_ASSET_RESOLVES_PER_CHUNK:
\t\t\t\tvar resolve_info := AssetCatalog.resolve(&"wall", WorldConstants.ASSET_VOCAB_WALL_2M)
\t\t\t\tvar has_asset: bool = bool(resolve_info.get("exists", false)) and resolve_info.get("scene", null) != null
\t\t\t\tif has_asset:
\t\t\t\t\tvar ws_center2: Vector2 = pr.get_center()
\t\t\t\t\tvar local_c: Vector2 = ws_center2 - (spec["rect"] as Rect2).position
\t\t\t\t\tvar asset_pos: Vector3 = off + Vector3(local_c.x, float(fi) * fh + fh*0.5 + WorldConstants.ASSET_LIFT_M, local_c.y)
\t\t\t\t\tvar is_vert_probe := pr.size.x < pr.size.y + 0.01
\t\t\t\t\tvar yaw_probe: float = 0.0 if is_vert_probe else PI * 0.5
\t\t\t\t\tvar asset_size: Vector3 = Vector3(2.0, WorldConstants.CITY_INTERIOR_OPEN_H, WorldConstants.CITY_INTERIOR_WALL_T)
\t\t\t\t\tb.queue_asset_wall(asset_pos, asset_size, WorldConstants.COL_ASSET_FALLBACK, String(resolve_info.get("res_path", "")), float(resolve_info.get("scale", 1.0)), bool(resolve_info.get("has_collision", false)), yaw_probe)
\t\t\t\t\tasset_handled = true
\t\t\t\tif asset_handled and b.asset_instance_count() == 1:
\t\t\t\t\tprint("[AssetPipeline] asset wall_2m resolve exists true fallback false at %s" % [str(resolve_info.get("res_path", ""))])
\t\t\t\telif not has_asset and b.asset_instance_count() == 0 and p == parts[0]:
\t\t\t\t\tprint("[AssetPipeline] asset wall_2m resolve exists false fallback true at %s" % [str(resolve_info.get("res_path", ""))])
\t\t\tif asset_handled:
\t\t\t\tcontinue
\t\t\tvar y0 := float(fi) * fh
\t\t\tvar wall_h := fh"""
if old in text:
    text = text.replace(old, new)
    p.write_text(text, encoding='utf-8')
    print("patched correct indent")
else:
    print("old not found")
    import re
    idx = text.find("# Partitions are along")
    print(repr(text[idx-100:idx+500]))
