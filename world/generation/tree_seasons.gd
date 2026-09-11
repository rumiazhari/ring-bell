class_name TreeSeasons
extends RefCounted
## Seasons — PLACEHOLDER (colour hooks only, no simulation yet).
##
## The geometry of a tree never changes with the season. Everything seasonal is
## a colour (and a leaf-density hint) looked up per species, so a future season
## system only has to call `foliage_color()` / `leaf_density()` with a different
## `Season` and the trees change appearance without regenerating a vertex.
##
## TODO(seasons): drive `current_season` from a real world clock, and give the
## winter case real deciduous bareness by *hiding* leaf clusters (the density
## hook returns a fraction; 0.0 means "no leaves"). Until then everything is
## pinned to summer: `current_season = Season.SUMMER`.

enum Season { SPRING = 0, SUMMER = 1, AUTUMN = 2, WINTER = 3 }

## PLACEHOLDER: pinned to summer. A future system sets this from the world clock.
static var current_season: Season = Season.SUMMER

const SEASON_NAMES := {
	Season.SPRING: "spring",
	Season.SUMMER: "summer",
	Season.AUTUMN: "autumn",
	Season.WINTER: "winter",
}

## Summer leaf colour per species (the reference the other seasons shift from).
## Keys match TreeBuilder.SPECIES.
const SUMMER := {
	&"beech": "3d5c2a", &"oak": "3e5226", &"birch": "5f7f38",
	&"spruce": "24402c", &"pine": "2d4a2e", &"linden": "47682c",
	&"maple": "456328", &"locust": "6a8a3e", &"chestnut": "3f5a1f",
	&"ash": "4d6b32",
}

## Autumn leaf colour (linden/maple gold, oak russet, beech copper,
## birch pale yellow, conifers stay green).
const AUTUMN := {
	&"beech": "8a5a24", &"oak": "7a4a1c", &"birch": "b8a63c",
	&"spruce": "24402c", &"pine": "2d4a2e", &"linden": "c9a227",
	&"maple": "b8791f", &"locust": "9a8a34", &"chestnut": "8a5c22",
	&"ash": "96702a",
}

## Spring flush — lighter, yellow-green new growth.
const SPRING := {
	&"beech": "6f8f3f", &"oak": "6a8438", &"birch": "8aa84e",
	&"spruce": "2c4a30", &"pine": "33502f", &"linden": "79a03c",
	&"maple": "6f9438", &"locust": "86a44a", &"chestnut": "6d8c30",
	&"ash": "7a9a44",
}

## Winter: bare broadleaves (density 0) keep their twig structure; conifers
## darken slightly.
const WINTER := {
	&"beech": "5a4a3a", &"oak": "54452f", &"birch": "6a6258",
	&"spruce": "1f3826", &"pine": "26402a", &"linden": "5c4c34",
	&"maple": "554a3c", &"locust": "5a4f3c", &"chestnut": "4f4030",
	&"ash": "5a5244",
}

const EVERGREEN := {
	&"spruce": true, &"pine": true, &"beech": false, &"oak": false,
	&"birch": false, &"linden": false, &"maple": false, &"locust": false,
	&"chestnut": false, &"ash": false,
}

static func season_name(s: int = -1) -> String:
	var key: int = s if s >= 0 else int(current_season)
	return String(SEASON_NAMES.get(key, "summer"))


static func is_evergreen(species: StringName) -> bool:
	return bool(EVERGREEN.get(species, false))


## Foliage colour for a species in a season. `shade` in [0,1] picks between the
## base colour and a darker/lighter variant so a tree's cluster cloud is not one
## flat tone (0.0 darker .. 1.0 brighter).
static func foliage_color(species: StringName, shade := 0.5, season := -1) -> Color:
	var key: int = season if season >= 0 else int(current_season)
	var table: Dictionary = SUMMER
	match key:
		Season.SPRING: table = SPRING
		Season.AUTUMN: table = AUTUMN
		Season.WINTER: table = WINTER
		_: table = SUMMER
	var hex: String = String(table.get(species, table.get(&"beech", "3d5c2a")))
	var base := Color(hex)
	var f: float = clampf(shade, 0.0, 1.0)
	if f < 0.5:
		return base.darkened((0.5 - f) * 0.5)
	return base.lightened((f - 0.5) * 0.5)


## Fraction of the summer leaf clusters to actually show. 1.0 = full summer
## canopy, 0.0 = bare. Conifers keep their needles year round.
## TODO(seasons): winter currently returns 0.0 for broadleaves but the generator
## only consumes this for `Season != SUMMER` trees built at spawn time.
static func leaf_density(species: StringName, season := -1) -> float:
	var key: int = season if season >= 0 else int(current_season)
	if is_evergreen(species):
		return 1.0
	match key:
		Season.SPRING: return 0.72
		Season.SUMMER: return 1.0
		Season.AUTUMN: return 0.62
		Season.WINTER: return 0.0
	return 1.0


## Bark colour is constant across seasons; kept here so callers have one table.
static func bark_color(species: StringName) -> Color:
	return Color(String(BARK.get(species, "5a4a3a")))


const BARK := {
	&"beech": "8a8f86", &"oak": "4a3a2a", &"birch": "d8d8d2",
	&"spruce": "4a3428", &"pine": "8a5a3a", &"linden": "5a4a3a",
	&"maple": "5f5348", &"locust": "6b5a45", &"chestnut": "4b3a2c",
	&"ash": "6a6157",
}
