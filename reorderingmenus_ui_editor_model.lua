-- Pure helpers shared by KOReader editor screens.

local EditorModel = {
    EMPTY_HINT_ID = "__empty_hint__",
}

function EditorModel.idsMatch(a, b)
    if #a ~= #b then return false end
    for index = 1, #a do
        if a[index] ~= b[index] then return false end
    end
    return true
end

function EditorModel.pageFor(item_count, items_per_page, current_page,
                             preferred_index)
    local per_page = math.max(1, tonumber(items_per_page) or 1)
    local pages = math.max(1, math.ceil(item_count / per_page))
    local page = preferred_index
        and math.ceil(preferred_index / per_page) or (current_page or 1)
    return pages, math.max(1, math.min(page, pages))
end

function EditorModel.removeRows(rows, predicate)
    local removed = 0
    for index = #rows, 1, -1 do
        if predicate(rows[index], index) then
            table.remove(rows, index)
            removed = removed + 1
        end
    end
    return removed
end

function EditorModel.removeRowsById(rows, item_id)
    return EditorModel.removeRows(rows, function(row)
        return row.item_id == item_id
    end)
end

function EditorModel.removeRow(rows, target)
    return EditorModel.removeRows(rows, function(row)
        return row == target
    end) > 0
end

function EditorModel.removeEmptyHints(rows)
    return EditorModel.removeRowsById(rows, EditorModel.EMPTY_HINT_ID)
end

function EditorModel.insertRow(rows, index, row)
    local clamped = math.max(1, math.min(tonumber(index) or (#rows + 1), #rows + 1))
    table.insert(rows, clamped, row)
    return clamped
end

function EditorModel.firstRowIndex(rows, predicate)
    for index, row in ipairs(rows) do
        if predicate(row, index) then return index end
    end
    return nil
end

-- Translate a position in the editor's row model to an insertion point in a
-- persisted id sequence. Rows omitted from persistence (such as the empty
-- hint) are ignored, while repeated ids such as separators retain multiplicity.
function EditorModel.persistedIndexForRowPosition(rows, row_position,
                                                   persisted_ids, ignored_id)
    local remaining = {}
    for index = 1, row_position - 1 do
        local row = rows[index]
        local item_id = row and row.item_id
        if item_id and item_id ~= ignored_id then
            remaining[item_id] = (remaining[item_id] or 0) + 1
        end
    end

    local last_matched = 0
    for index, item_id in ipairs(persisted_ids) do
        if (remaining[item_id] or 0) > 0 then
            remaining[item_id] = remaining[item_id] - 1
            last_matched = index
        end
    end
    return last_matched + 1
end

return EditorModel
