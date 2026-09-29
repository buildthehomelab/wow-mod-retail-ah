-- The Buy tab's category tree, retail's order with WotLK's item classes. Each node filters on
-- item class, subclass and inventory type (nil = any), matched on the server.

local RAH = RetailAH

local function node(name, class, subclass, invtype, children)
	return { name = name, class = class, subclass = subclass, invtype = invtype, children = children }
end

local function slots(class, subclass, list)
	local children = {}
	for _, s in ipairs(list) do table.insert(children, node(s[1], class, subclass, s[2])) end
	return children
end

local ARMOR_SLOTS = {
	{ "Head", 1 }, { "Shoulder", 3 }, { "Chest", 5 }, { "Waist", 6 }, { "Legs", 7 },
	{ "Feet", 8 }, { "Wrist", 9 }, { "Hands", 10 },
}

local CLOTH_SLOTS = {
	{ "Head", 1 }, { "Shoulder", 3 }, { "Chest", 5 }, { "Waist", 6 }, { "Legs", 7 },
	{ "Feet", 8 }, { "Wrist", 9 }, { "Hands", 10 }, { "Back", 16 },
}

local MISC_ARMOR = {
	{ "Neck", 2 }, { "Finger", 11 }, { "Trinket", 12 }, { "Held In Off-hand", 23 },
	{ "Shirt", 4 }, { "Tabard", 19 },
}

RAH.CATEGORIES = {
	node("Weapons", 2, nil, nil, {
		node("One-Handed Axes", 2, 0), node("One-Handed Maces", 2, 4), node("One-Handed Swords", 2, 7),
		node("Daggers", 2, 15), node("Fist Weapons", 2, 13),
		node("Two-Handed Axes", 2, 1), node("Two-Handed Maces", 2, 5), node("Two-Handed Swords", 2, 8),
		node("Polearms", 2, 6), node("Staves", 2, 10),
		node("Bows", 2, 2), node("Crossbows", 2, 18), node("Guns", 2, 3), node("Thrown", 2, 16), node("Wands", 2, 19),
		node("Fishing Poles", 2, 20), node("Miscellaneous", 2, 14),
	}),
	node("Armor", 4, nil, nil, {
		node("Plate", 4, 4, nil, slots(4, 4, ARMOR_SLOTS)),
		node("Mail", 4, 3, nil, slots(4, 3, ARMOR_SLOTS)),
		node("Leather", 4, 2, nil, slots(4, 2, ARMOR_SLOTS)),
		node("Cloth", 4, 1, nil, slots(4, 1, CLOTH_SLOTS)),
		node("Miscellaneous", 4, 0, nil, slots(4, 0, MISC_ARMOR)),
		node("Shields", 4, 6), node("Librams", 4, 7), node("Idols", 4, 8), node("Totems", 4, 9), node("Sigils", 4, 10),
	}),
	node("Containers", 1, nil, nil, {
		node("Bags", 1, 0), node("Soul Bags", 1, 1), node("Herb Bags", 1, 2), node("Enchanting Bags", 1, 3),
		node("Engineering Bags", 1, 4), node("Gem Bags", 1, 5), node("Mining Bags", 1, 6),
		node("Leatherworking Bags", 1, 7), node("Inscription Bags", 1, 8),
	}),
	node("Gems", 3, nil, nil, {
		node("Red", 3, 0), node("Blue", 3, 1), node("Yellow", 3, 2), node("Purple", 3, 3),
		node("Green", 3, 4), node("Orange", 3, 5), node("Meta", 3, 6), node("Simple", 3, 7), node("Prismatic", 3, 8),
	}),
	node("Item Enhancement", 0, 6, nil, {
		node("Enchantments", 0, 6), node("Armor Enchantments", 7, 14), node("Weapon Enchantments", 7, 15),
	}),
	node("Consumables", 0, nil, nil, {
		node("Food & Drink", 0, 5), node("Potions", 0, 1), node("Elixirs", 0, 2), node("Flasks", 0, 3),
		node("Bandages", 0, 7), node("Scrolls", 0, 4), node("Other", 0, 8), node("Consumable", 0, 0),
	}),
	node("Glyphs", 16, nil, nil, {
		node("Death Knight", 16, 6), node("Druid", 16, 11), node("Hunter", 16, 3), node("Mage", 16, 8),
		node("Paladin", 16, 2), node("Priest", 16, 5), node("Rogue", 16, 4), node("Shaman", 16, 7),
		node("Warlock", 16, 9), node("Warrior", 16, 1),
	}),
	node("Trade Goods", 7, nil, nil, {
		node("Cloth", 7, 5), node("Leather", 7, 6), node("Metal & Stone", 7, 7), node("Herbs", 7, 9),
		node("Elemental", 7, 10), node("Enchanting", 7, 12), node("Jewelcrafting", 7, 4), node("Meat", 7, 8),
		node("Parts", 7, 1), node("Devices", 7, 3), node("Explosives", 7, 2), node("Materials", 7, 13),
		node("Other", 7, 11),
	}),
	node("Recipes", 9, nil, nil, {
		node("Alchemy", 9, 6), node("Blacksmithing", 9, 4), node("Cooking", 9, 5), node("Enchanting", 9, 8),
		node("Engineering", 9, 3), node("First Aid", 9, 7), node("Fishing", 9, 9), node("Inscription", 9, 11),
		node("Jewelcrafting", 9, 10), node("Leatherworking", 9, 1), node("Tailoring", 9, 2), node("Books", 9, 0),
	}),
	node("Projectiles", 6, nil, nil, { node("Arrows", 6, 2), node("Bullets", 6, 3) }),
	node("Quivers", 11, nil, nil, { node("Quivers", 11, 2), node("Ammo Pouches", 11, 3) }),
	node("Companion Pets", 15, 2),
	node("Mounts", 15, 5),
	node("Quest Items", 12),
	node("Miscellaneous", 15, nil, nil, {
		node("Junk", 15, 0), node("Reagents", 15, 1), node("Holiday", 15, 3), node("Other", 15, 4),
	}),
}

-- The rarity checkboxes in the filter panel.
RAH.QUALITIES = {
	{ 0, ITEM_QUALITY0_DESC }, { 1, ITEM_QUALITY1_DESC }, { 2, ITEM_QUALITY2_DESC }, { 3, ITEM_QUALITY3_DESC },
	{ 4, ITEM_QUALITY4_DESC }, { 5, ITEM_QUALITY5_DESC }, { 7, ITEM_QUALITY7_DESC },
}
