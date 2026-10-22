-- mod-retail-ah: era overrides for AzerothCore loot data the module would otherwise read wrong.
-- Each item below also has an old-world source that is a data quirk, so taking the easiest
-- source would show it from the start. Crafts and containers made from them follow.
-- INSERT IGNORE, so a row you have already set for one of these items stays as it is.
--
-- Found by checking every profession item (trade goods, gems, recipes, consumables, reagents)
-- against the module's source rules: Outland or Northrend sources on one side, a handful of
-- incidental old-world ones on the other.

INSERT IGNORE INTO `mod_retail_ah_item_era` (`entry`, `state`, `comment`) VALUES
-- Duros and Drakan (12122/12121), level 60 Alterac Valley creatures, share their skinning
-- tables with their level 70/80 copies, which hold Outland leather.
(21887, 8, 'Knothide Leather: Outland skinning; Duros/Drakan (AV) tables shared with TBC copies'),
(25649, 8, 'Knothide Leather Scraps: Outland skinning; Duros/Drakan (AV) tables shared with TBC copies'),
-- Pickpocket tables of level 60-62 old-world humanoids include Outland potions and food.
(22829, 8, 'Super Healing Potion: Outland loot; old-world level 60-62 pickpocket tables'),
(27854, 8, 'Smoked Talbuk Venison: Outland loot; old-world level 61-62 pickpocket tables'),
(27859, 8, 'Zangar Caps: Outland loot; old-world level 60-62 pickpocket tables'),
-- Level 61-62 dragonkin (Scalebane, Wyrmkin) share an Outland scroll reference.
(27498, 8, 'Scroll of Agility V: Outland loot; level 61-62 old-world dragonkin'),
(27499, 8, 'Scroll of Intellect V: Outland loot; level 61-62 old-world dragonkin'),
(27500, 8, 'Scroll of Protection V: Outland loot; level 61-62 old-world dragonkin'),
(27501, 8, 'Scroll of Spirit V: Outland loot; level 61-62 old-world dragonkin'),
(27502, 8, 'Scroll of Stamina V: Outland loot; level 61-62 old-world dragonkin'),
(27503, 8, 'Scroll of Strength V: Outland loot; level 61-62 old-world dragonkin'),
-- Fishing in zone 41 (Deadwind Pass) lists Outland and Zul''Aman fish.
(27422, 8, 'Barbed Gill Trout: Outland fishing; also in the Deadwind Pass fishing table'),
(33823, 12, 'Bloodfin Catfish: Zul''Aman fishing; also in the Deadwind Pass fishing table'),
(33824, 12, 'Crescent-Tail Skullfish: Zul''Aman fishing; also in the Deadwind Pass fishing table');
