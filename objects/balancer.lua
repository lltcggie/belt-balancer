require("helper.math")
require("util")
require("helper.conversion")

balancer_functions = {}

---creates a new balancer object in the global stack
---This will NOT set the parts and the lanes!!
---@return Balancer the created balancer
function balancer_functions.new()
    ---@type Balancer
    local balancer = {}

    balancer.unit_number = get_next_balancer_unit_number()
    balancer.parts = {}
    balancer.nth_tick = 0
    balancer.buffer = {}
    balancer.input_lanes = {}
    balancer.output_lanes = {}
    balancer.next_input = 1
    balancer.next_output = 1

    global.balancer[balancer.unit_number] = balancer

    return balancer
end

---merge two balancer, the first balancer_index is the base, to merge things into.
---The second balancer (balancer_index2) will be deleted after it is merged.
---@param balancer_index uint
---@param balancer_index2 uint
function balancer_functions.merge(balancer_index, balancer_index2)
    local balancer = global.balancer[balancer_index]
    local balancer2 = global.balancer[balancer_index2]

    for k, part_index in pairs(balancer2.parts) do
        balancer.parts[k] = part_index

        -- change balancer link on part too
        local part = global.parts[part_index]
        part.balancer = balancer_index

        -- change balancer link on belts too
        for _, belt_index in pairs(part.input_belts) do
            local belt = global.belts[belt_index]
            belt.output_balancer[balancer_index2] = nil
            belt.output_balancer[balancer_index] = balancer_index
        end

        for _, belt_index in pairs(part.output_belts) do
            local belt = global.belts[belt_index]
            belt.input_balancer[balancer_index2] = nil
            belt.input_balancer[balancer_index] = balancer_index
        end
    end

    for i=1, #balancer2.input_lanes do
        table.insert(balancer.input_lanes, balancer2.input_lanes[i])
    end

    for i=1, #balancer2.output_lanes do
        table.insert(balancer.output_lanes, balancer2.output_lanes[i])
    end

    for _, item in pairs(balancer2.buffer) do
        table.insert(balancer.buffer, item)
    end

    -- remove merged balancer from the global stack
    global.balancer[balancer_index2] = nil

    -- unregister nth_tick
    unregister_on_tick(balancer_index2)
end

---This will find nearby balancer, creates/adds/merges balancer if needed.
---The part is automatically added to the balancer!
---@param part Part The part entity to work from
---@return uint The balancer index, that the part is part of :)
function balancer_functions.find_from_part(part)
    if part.balancer ~= nil then
        return part.balancer
    end

    local entity = part.entity

    local nearby_balancer_indices = part_functions.find_nearby_balancer(entity)
    local nearby_balancer_amount = table_size(nearby_balancer_indices)

    if nearby_balancer_amount == 0 then
        -- create new balancer
        local balancer = balancer_functions.new()
        balancer.parts[entity.unit_number] = entity.unit_number
        return balancer.unit_number
    elseif nearby_balancer_amount == 1 then
        -- add to existing balancer
        local balancer
        for _, index in pairs(nearby_balancer_indices) do
            balancer = global.balancer[index]
            balancer.parts[entity.unit_number] = entity.unit_number
        end
        return balancer.unit_number
    elseif nearby_balancer_amount >= 2 then
        -- add to existing balancer and merge them
        -- merge fond balancer
        local base_balancer_index
        for _, nearby_balancer_index in pairs(nearby_balancer_indices) do
            if not base_balancer_index then
                base_balancer_index = nearby_balancer_index

                -- add splitter to balancer
                local balancer = global.balancer[nearby_balancer_index]
                balancer.parts[entity.unit_number] = entity.unit_number
            else
                -- merge balancer and remove them from global table
                balancer_functions.merge(base_balancer_index, nearby_balancer_index)
            end
        end
        return base_balancer_index
    end
end

---recalculate_nth_tick
---@param balancer_index uint
function balancer_functions.recalculate_nth_tick(balancer_index)
    local balancer = global.balancer[balancer_index]

    if #balancer.input_lanes == 0 or #balancer.output_lanes == 0 or table_size(balancer.parts) == 0 then
        unregister_on_tick(balancer_index)
        balancer.nth_tick = 0
        return
    end

    -- recalculate nth_tick
    local tick_list = {}
    local run_on_tick_override = false

    for _, part in pairs(balancer.parts) do
        local stack_part = global.parts[part]
        for _, belt in pairs(stack_part.output_belts) do
            local stack_belt = global.belts[belt]
            local belt_speed = stack_belt.entity.prototype.belt_speed
            local ticks_per_tile = 0.25 / belt_speed
            local nth_tick = math.floor(ticks_per_tile)
            if nth_tick ~= ticks_per_tile then
                run_on_tick_override = true
                break
            end
            tick_list[nth_tick] = nth_tick
        end

        if run_on_tick_override then
            break
        end
    end

    local smallest_gcd = -1
    if not run_on_tick_override then
        for _, tick in pairs(tick_list) do
            if smallest_gcd == -1 then
                smallest_gcd = tick
            elseif smallest_gcd == 1 then
                break
            elseif smallest_gcd == tick then
                -- do nothing
            else
                smallest_gcd = math.gcd(smallest_gcd, tick)
            end
        end
    end

    if run_on_tick_override then
        smallest_gcd = 1
    end
    if smallest_gcd ~= -1 and balancer.nth_tick ~= smallest_gcd then
        balancer.nth_tick = smallest_gcd
        unregister_on_tick(balancer_index)
        register_on_tick(smallest_gcd, balancer_index)
    end
end

function balancer_functions.run(balancer_index)
    local balancer = global.balancer[balancer_index]
    local input_lane_count = #balancer.input_lanes
    local output_lane_count = #balancer.output_lanes

    if input_lane_count > 0 and output_lane_count > 0 then
        local next_input = balancer.next_input
        local next_output = balancer.next_output

        local input_index = 1
        local output_index = 1

        local lanes = global.lanes

        if input_lane_count <= 32 then -- 入力レーン数が32以下ならビット演算できるので全入力レーンが空になったら処理を打ち切るバージョンを実行する
            local bit32_replace = bit32.replace
            local not_empty_lane_bits = bit32_replace(0, 0xFFFFFFFF, 0, input_lane_count)

            -- まず出力先があるか見る
            -- MEMO: 同じような処理が下にあるので、処理を直す場合はそちらも直すのを忘れないようにすること
            for j=0, output_lane_count - 1 do
                if next_output <= output_lane_count then
                    output_index = next_output
                else
                    output_index = 1
                end

                local output_lane_index = balancer.output_lanes[output_index]
                local output_lane = lanes[output_lane_index]

                if output_lane.can_insert_at_back() then
                    -- 出力先が見つかったら入力アイテムがあるか見て存在したら出力先に配置
                    for i=0, input_lane_count - 1 do
                        if next_input <= input_lane_count then
                            input_index = next_input
                        else
                            input_index = 1
                        end

                        next_input = input_index + 1

                        local input_lane_index = balancer.input_lanes[input_index]
                        local input_lane = lanes[input_lane_index]
                        local input_lane_item_count = #input_lane
                        if input_lane_item_count > 0 then
                            local lua_item = input_lane[1]

                            if output_lane.insert_at_back(lua_item) then
                                input_lane.remove_item(lua_item)
                                next_output = output_index + 1
                                if input_lane_item_count == 1 then -- 消費したのが入力レーンの最後の1個だったら
                                    not_empty_lane_bits = bit32_replace(not_empty_lane_bits, 0, input_index - 1)
                                    if not_empty_lane_bits == 0 then -- 全入力レーンが空になったので終了
                                        goto exit
                                    end
                                    break
                                end
                                break
                            end
                        end
                    end
                else
                    next_output = output_index + 1
                end
            end

            ::exit::
            balancer.next_input = next_input
            balancer.next_output = next_output
        else
            -- まず出力先があるか見る
            for j=0, output_lane_count - 1 do
                if next_output <= output_lane_count then
                    output_index = next_output
                else
                    output_index = 1
                end

                local output_lane_index = balancer.output_lanes[output_index]
                local output_lane = lanes[output_lane_index]

                if output_lane.can_insert_at_back() then
                    -- 出力先が見つかったら入力アイテムがあるか見て存在したら出力先に配置
                    for i=0, input_lane_count - 1 do
                        if next_input <= input_lane_count then
                            input_index = next_input
                        else
                            input_index = 1
                        end

                        next_input = input_index + 1

                        local input_lane_index = balancer.input_lanes[input_index]
                        local input_lane = lanes[input_lane_index]
                        if #input_lane > 0 then
                            local lua_item = input_lane[1]

                            if output_lane.insert_at_back(lua_item) then
                                input_lane.remove_item(lua_item)
                                next_output = output_index + 1
                                break
                            end
                        end
                    end
                else
                    next_output = output_index + 1
                end
            end

            balancer.next_input = next_input
            balancer.next_output = next_output
        end
    end
end

---check if this balancer still needs to be tracked, if not, remove it from global stack!
---@param balancer_index uint
---@param drop_to Item_drop_param
---@return boolean True if balancer is still tracked, false if balancer was removed
function balancer_functions.check_track(balancer_index, drop_to)
    local balancer = global.balancer[balancer_index]
    if table_size(balancer.parts) == 0 then
        -- balancer is not valid, remove it from global stack
        if #balancer.output_lanes > 0 or #balancer.input_lanes > 0 then
            print("Belt-balancer: Something is off with the removing of balancer lanes")
            print("balancer: ", balancer_index)
            print(serpent.block(global.balancer))
        end

        balancer_functions.empty_buffer(balancer, drop_to)

        global.balancer[balancer_index] = nil

        return false
    end

    return true
end

---empty_buffer
---@overload fun(balancer:Balancer, buffer:LuaInventory)
---@param balancer Balancer
---@param drop_to Item_drop_param
function balancer_functions.empty_buffer(balancer, drop_to)
    if drop_to.buffer and drop_to.buffer.valid then
        for _, item in pairs(balancer.buffer) do
            drop_to.buffer.insert(item)
        end
    else
        -- drop items on ground
        for _, item in pairs(balancer.buffer) do
            drop_to.surface.spill_item_stack(drop_to.position, item, false, drop_to.force)
        end
    end
end

---balancer_get_linked
---get all lined splitters into an array of LuaEntity
---@param balancer Balancer balancer to perform on
---@return LuaEntity[][]
function balancer_functions.get_linked(balancer)
    -- create matrix
    local matrix = {}
    for _, part_index in pairs(balancer.parts) do
        local part = global.parts[part_index]
        local pos = part.entity.position
        if not matrix[pos.x] then
            matrix[pos.x] = {}
        end
        matrix[pos.x][pos.y] = part.entity
    end

    local curr_num = 0
    local result = {}
    repeat
        curr_num = curr_num + 1
        balancer_functions.expand_first(matrix, curr_num, result)
    until (table_size(matrix) == 0)
    return result
end

---balancer_expand_first
---expand the first found not expanded Element in the matrix
---@param matrix LuaEntity[][] matrix to perform logic on
---@param num number
function balancer_functions.expand_first(matrix, num, result)
    for x_key, _ in pairs(matrix) do
        local breaker = false
        for y_key, _ in pairs(matrix[x_key]) do
            if matrix[x_key][y_key] then
                result[num] = {}
                balancer_functions.expand_matrix(matrix, { x = x_key, y = y_key }, num, result)
                breaker = true
                break
            end
        end

        if breaker then
            break
        end
    end
end

---balancer_expand_matrix
---expand given element in the matrix and then expand its neighbours
---only expand if this element is not nil
function balancer_functions.expand_matrix(matrix, pos, num, result)
    if matrix[pos.x] and matrix[pos.x][pos.y] then
        local part_entity = matrix[pos.x][pos.y]
        result[num][part_entity.unit_number] = part_entity
        matrix[pos.x][pos.y] = nil
        if table_size(matrix[pos.x]) == 0 then
            matrix[pos.x] = nil
        end

        balancer_functions.expand_matrix(matrix, { x = pos.x - 1, y = pos.y }, num, result)
        balancer_functions.expand_matrix(matrix, { x = pos.x + 1, y = pos.y }, num, result)
        balancer_functions.expand_matrix(matrix, { x = pos.x, y = pos.y - 1 }, num, result)
        balancer_functions.expand_matrix(matrix, { x = pos.x, y = pos.y + 1 }, num, result)
    end
end

---create a new balancer with already created parts
---@param part_list LuaEntity[]
---@return Balancer
function balancer_functions.new_from_part_list(part_list)
    local balancer = balancer_functions.new()

    for _, part_entity in pairs(part_list) do
        local part = global.parts[part_entity.unit_number]

        -- add part to balancer
        balancer.parts[part_entity.unit_number] = part_entity.unit_number

        -- add balancer to part
        part.balancer = balancer.unit_number

        for _, belt_index in pairs(part.input_belts) do
            local belt = global.belts[belt_index]

            -- add balancer to belt
            belt.output_balancer[balancer.unit_number] = balancer.unit_number
        end

        for _, belt_index in pairs(part.output_belts) do
            local belt = global.belts[belt_index]

            -- add balancer to belt
            belt.input_balancer[balancer.unit_number] = balancer.unit_number
        end

        -- add lanes to balancer
        for i=1, #part.input_lanes do
            table.insert(balancer.input_lanes, part.input_lanes[i])
        end
        for i=1, #part.output_lanes do
            table.insert(balancer.output_lanes, part.output_lanes[i])
        end
    end

    balancer_functions.recalculate_nth_tick(balancer.unit_number)

    return balancer
end

---check if this balancer still is one piece, if not, create multiple balancer if needed.
---@param balancer_index uint
---@param drop_to Item_drop_param
function balancer_functions.check_connected(balancer_index, drop_to)
    local balancer = global.balancer[balancer_index]

    local linked = balancer_functions.get_linked(balancer)
    if table_size(linked) > 1 then
        -- unregister balancer, before splitting it
        unregister_on_tick(balancer_index)

        -- create multiple new balancer
        for _, parts in pairs(linked) do
            balancer_functions.new_from_part_list(parts)
        end

        -- remove old balancer from belts
        for _, part_index in pairs(balancer.parts) do
            local part = global.parts[part_index]
            for _, belt_index in pairs(part.input_belts) do
                local belt = global.belts[belt_index]
                belt.input_balancer[balancer_index] = nil
                belt.output_balancer[balancer_index] = nil
            end
            for _, belt_index in pairs(part.output_belts) do
                local belt = global.belts[belt_index]
                belt.input_balancer[balancer_index] = nil
                belt.output_balancer[balancer_index] = nil
            end
        end

        -- clear the old balancer buffer
        balancer_functions.empty_buffer(balancer, drop_to)

        -- finally, remove old balancer form global stack
        global.balancer[balancer_index] = nil
    end
end

return balancer_functions
