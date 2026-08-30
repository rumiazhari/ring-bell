class_name SkeletonFactory
extends RefCounted
## Builds a 10-bone human skeleton (root/hips/spine_upper/head/l_thigh/l_shin/r_thigh/r_shin/l_upper_arm/r_upper_arm)
## Hip at y 0.86, spine_upper at 0.95 matching HumanoidModel pivots, scaled 1.2 via model attachment.
## Primitive meshes from HumanoidModel are attached via BoneAttachment3D per limb.

static func capsule_heights() -> Dictionary:
	return {"stand": 1.7, "crouch": 1.25, "slide": 1.00}

static func bone_names() -> PackedStringArray:
	return PackedStringArray(["root", "hips", "spine_upper", "head", "l_thigh", "l_shin", "r_thigh", "r_shin", "l_upper_arm", "r_upper_arm"])

static func build_survivor_skeleton() -> Skeleton3D:
	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	var names: PackedStringArray = bone_names()
	# parent indices: root -1, hips->root, spine_upper->hips, head->spine_upper, l_thigh->hips, l_shin->l_thigh, r_thigh->hips, r_shin->r_thigh, l_upper_arm->spine_upper, r_upper_arm->spine_upper
	var parents := [-1, 0, 1, 2, 1, 4, 1, 6, 2, 2]
	# local rest offsets (relative to parent)
	# shoulder half-width 0.19 + 0.06 =0.25
	var rest_positions := [
		Vector3.ZERO,
		Vector3(0, 0.86, 0),
		Vector3(0, 0.09, 0),
		Vector3(0, 0.78, 0.005),
		Vector3(-0.11, 0, 0),
		Vector3(0, -0.84, 0),
		Vector3(0.11, 0, 0),
		Vector3(0, -0.84, 0),
		Vector3(-0.25, 0.51, 0),
		Vector3(0.25, 0.51, 0),
	]
	for i in names.size():
		var idx := skel.add_bone(names[i])
		if parents[i] >= 0:
			skel.set_bone_parent(idx, parents[i])
		var rest := Transform3D(Basis.IDENTITY, rest_positions[i])
		skel.set_bone_rest(idx, rest)
		skel.set_bone_pose_position(idx, Vector3.ZERO)
		skel.set_bone_pose_rotation(idx, Quaternion.IDENTITY)
		skel.set_bone_pose_scale(idx, Vector3.ONE)
	return skel

static func attach_model(skeleton: Skeleton3D, model_root: Node3D) -> void:
	if skeleton == null or model_root == null:
		return
	if not is_instance_valid(skeleton) or not is_instance_valid(model_root):
		return
	# Map pivot names (HumanoidModel) to bone names
	var mapping := {
		"l_leg": "l_thigh",
		"r_leg": "r_thigh",
		"l_arm": "l_upper_arm",
		"r_arm": "r_upper_arm",
		"upper": "spine_upper"
	}
	var anim_limbs: Dictionary = {}
	if model_root.has_meta("anim_limbs"):
		anim_limbs = model_root.get_meta("anim_limbs") as Dictionary
	for pivot_name in mapping.keys():
		var bone_name: String = mapping[pivot_name]
		var pivot: Node3D = anim_limbs.get(pivot_name, null) as Node3D
		if pivot == null or not is_instance_valid(pivot):
			continue
		var bone_idx := skeleton.find_bone(bone_name)
		if bone_idx < 0:
			continue
		# avoid duplicate attachments
		var existing: BoneAttachment3D = null
		for child in skeleton.get_children():
			if child is BoneAttachment3D and (child as BoneAttachment3D).bone_name == bone_name:
				existing = child
				break
		var attachment: BoneAttachment3D
		if existing != null:
			attachment = existing
		else:
			attachment = BoneAttachment3D.new()
			attachment.name = "Attach_%s" % bone_name
			attachment.bone_name = bone_name
			attachment.bone_idx = bone_idx
			skeleton.add_child(attachment)
		# Move MeshInstance3D children from pivot into attachment, preserving local transforms
		var to_move: Array[MeshInstance3D] = []
		for child in pivot.get_children():
			if child is MeshInstance3D:
				to_move.append(child as MeshInstance3D)
		for mi in to_move:
			pivot.remove_child(mi)
			attachment.add_child(mi)
			# MeshInstance stays at same local position relative to attachment as it was to pivot
			# No adjustment needed because both pivots are at same bone position (hips-relative)
	# Hip-level skirt cloth: if female model has SkirtCloth under model_root, attach to hips
	for child in model_root.get_children():
		if child.has_method("setup") and child.get_script() != null and String(child.get_script().resource_path).contains("skirt"):
			# SkirtCloth node - attach to hips bone
			var hips_idx := skeleton.find_bone("hips")
			if hips_idx >= 0:
				var hips_attach: BoneAttachment3D = null
				for c in skeleton.get_children():
					if c is BoneAttachment3D and (c as BoneAttachment3D).bone_name == "hips":
						hips_attach = c
						break
				if hips_attach == null:
					hips_attach = BoneAttachment3D.new()
					hips_attach.name = "Attach_hips"
					hips_attach.bone_name = "hips"
					hips_attach.bone_idx = hips_idx
					skeleton.add_child(hips_attach)
				# Reparent skirt if not already
				if child.get_parent() == model_root:
					model_root.remove_child(child)
					hips_attach.add_child(child)
					child.position = Vector3.ZERO
			break
