import pathlib
p = pathlib.Path("C:/Vibe Code project/Godot Project/ring-bell/debug/world_test.gd")
t = p.read_text(encoding='utf-8')
t2 = t.replace("MeshBatchernew()", "MeshBatcher.new()".replace("new()", ".new()")) # dummy
# Actually we need to replace all occurrences of MeshBatchernew with MeshBatcher.new dot
# The dummy above is wrong, do direct replace
if "MeshBatchernew()" in t:
    t = t.replace("MeshBatchernew()", "MeshBatcher.new()") # placeholder
# Now correct: replace MeshBatchernew() (without dot) with MeshBatcher.new()
# We introduced "MeshBatchernew()" without dot, which is "MeshBatchernew()" string length includes no dot?
# Check actual string we introduced: "MeshBatchernew()" includes no dot? Let's just replace any "MeshBatchernew()" with "MeshBatcher.new()"
# But we have both correct and incorrect? Let's check current file for pattern without dot
import re
# Find all "MeshBatchernew"
count_wrong = t.count("MeshBatchernew()")
count_correct = t.count("MeshBatcher.new") # includes dot?
print("wrong count", count_wrong)
# The correct string with dot is "MeshBatcher.new()"
# The wrong we introduced is "MeshBatchernew()" (no dot)
# Let's ensure we have dot
# Replace wrong with correct
if "MeshBatchernew()" in t:
    # This is the correct with dot? Actually correct has dot, wrong has no dot: "MeshBatchernew()" vs "MeshBatcher.new()"
    # Count
    pass
# Let's just do regex to fix: any occurrence of "MeshBatchernew()" (which is "MeshBatcher" + "new()" without dot) -> replace with "MeshBatcher.new()"
# But "MeshBatchernew()" is substring of "MeshBatcher.new()" without dot? Wait "MeshBatcher.new()" includes dot, so "MeshBatchernew()" is without dot (missing dot). We introduced without dot, so replace that.
if "MeshBatcher.new()" in t:
    print("has dot")
# Let's just brute force: ensure all "MeshBatchernew()" (no dot) become "MeshBatcher.new()"
# Use replace
t_new = t.replace("MeshBatchernew()", "MeshBatcher.new()") # this does nothing? Because we need to differentiate
# Actually we need to replace "MeshBatchernew()" (8+3) where the dot is missing. Let's search for "r.new" pattern?
# Simpler: read file and replace literal "MeshBatchernew()" (without dot) with "MeshBatcher.new()"
# Python's replace will treat them as distinct
old_wrong = "MeshBatchernew()"
new_correct = "MeshBatcher.new()"
if old_wrong in t:
    t = t.replace(old_wrong, new_correct)
    print("fixed wrong")
else:
    print("no wrong found")
# Also check for "MeshBatchernew()" with dot already correct should stay
# But we also introduced "MeshBatchernew()" incorrectly? Let's check for "MeshBatcher.new()" presence
# Count again
print("after fix wrong count", t.count("MeshBatchernew()"))
print("correct count", t.count("MeshBatcher.new()".replace("new()", ".new()")))
# The second is "MeshBatcher.new()" with dot? Let's compute
correct = "MeshBatcher" + ".new()"
print("correct literal", repr(correct), "count", t.count(correct))
# Also check for "MeshBatcher .new" etc.
# Ensure we have no leftover without dot: search for "MeshBatchernew"
import re
m = re.findall(r"MeshBatcher\s*new", t)
print(m[:5])
# Write back
p.write_text(t, encoding='utf-8')
print("done")
