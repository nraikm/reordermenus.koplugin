-- W repro 4: gh_item_1/2 pinned to tools; after providers vanish, are
-- they still VISIBLE in tools? (They should NOT be.)
package.path = "/Users/nr/Development/ReorderingMenus/?.lua;" .. package.path
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua')
