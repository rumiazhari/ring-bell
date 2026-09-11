import pathlib
p = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/debug/world_test.gd")
t = p.read_text(encoding='utf-8')
# Fix all occurrences where MeshBatchernew without dot appears
# The pattern without dot is "MeshBatchernew()" ; with dot is "MeshBatcher.new()"
if "MeshBatchernew()" in t:
    t = t.replace("MeshBatchernew()", "MeshBatcher.new()")
    # Actually we need to replace without dot with with dot
    # Let's do properly: find without dot and replace
    # Without dot string
    without = "MeshBatcher" + "new()"
    withdot = "MeshBatcher.new()"
    # without is "MeshBatchernew()" (no dot), withdot is "MeshBatcher.new()" (with dot)
    # Check
    print("without in t?", without in t)
    print("withdot count before", t.count(withdot))
    # Do replace
    t2 = t.replace(without, withdot)
    print("after replace without count", t2.count(without))
    print("after withdot count", t2.count(withdot))
    p.write_text(t2, encoding='utf-8')
    print("fixed")
else:
    print("no without found")
    print("count withdot", t.count("MeshBatcher.new()"))
