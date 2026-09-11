import pathlib
p = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/debug/world_test.gd")
t = p.read_text(encoding='utf-8')
wrong = "MeshBatchernew()"
correct = "MeshBatcher.new()".replace("new()", ".new()")  # trick to get correct with dot
# Actually correct is "MeshBatcher.new()"
correct = "MeshBatcher.new()"
# But wrong is without dot, correct with dot
wrong2 = "MeshBatchernew()"
# Let's just directly check
print("before wrong count", t.count(wrong2))
print("before correct", t.count(correct))
# Replace wrong with correct
if wrong2 in t:
    t = t.replace(wrong2, correct)
    p.write_text(t, encoding='utf-8')
    print("fixed")
    print("after wrong", t.count(wrong2))
    print("after correct", t.count(correct))
else:
    print("wrong not found")
