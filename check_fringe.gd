
extends SceneTree
func _init():
    var s = load("res://world/generation/fringe_plan.gd")
    print("load fringe_plan: ", s, " err ", "null" if s==null else "ok")
    if s != null:
        var inst = s.new(19041207)
        print("inst ok buildings ", inst.fringe_buildings().size())
    quit()
