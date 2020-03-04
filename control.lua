require("objects.global")
require("objects.balancer")
require("objects.part")
require("objects.belt")
require("helper.message-handler")
require("test")

-- on new savegame and on adding mod to existing save
script.on_init(function()
    -- set defaults and initialize values in global table
    global.next_balancer_unit_number = 1
    global.next_lane_unit_number = 1
    global.balancer = {}
    global.parts = {}
    global.belts = {}
    global.lanes = {}
    global.events = {}
end)

script.on_load(reregister_on_tick)

-- If some mod is changed, check if boblogistics got added and do stuff :)
script.on_configuration_changed(
    function(e)
        ---@type ModConfigurationChangedData
        local boblogistics_changes = e.mod_changes["boblogistics"]

        if boblogistics_changes and boblogistics_changes.old_version == nil and boblogistics_changes.new_version and settings.startup["bobmods-logistics-beltoverhaul"].value == true then
            -- on boblogistics got added!
            for _, force in pairs(game.forces) do
                local technologies = force.technologies
                local recipes = force.recipes

                technologies["belt-balancer-0"].researched = technologies["belt-balancer-1"].researched
                recipes["belt-balancer-basic-belt"].enabled = technologies["belt-balancer-1"].researched
            end
        end
    end
)


-- Custom command to print out some statistics
commands.add_command("belt-balancer-statistics", "", function(e)
    local balancer_amount = table_size(global.balancer)
    local balancer_part_amount = table_size(global.parts)
    local balancer_input_belt_amount = 0
    local balancer_output_belt_amount = 0

    for _, balancer in pairs(global.balancer) do
        for _, v in pairs(balancer.parts) do
            balancer_input_belt_amount = balancer_input_belt_amount + table_size(global.parts[v].input_belts)
            balancer_output_belt_amount = balancer_output_belt_amount + table_size(global.parts[v].output_belts)
        end
    end

    local output = "balancers: " .. balancer_amount ..
        "\nbalancer-parts: " .. balancer_part_amount ..
        "\nbalancer_input_belts: " .. balancer_input_belt_amount ..
        "\nbalancer_output_belts: " .. balancer_output_belt_amount
    game.get_player(e.player_index).print(output)
    print(output)
end)

-- only add this command, if `debug` is available and creative-mod is activated
-- `debug` can be activated, when calling factorio with `--instrument-mod belt-balancer`
if debug and script.active_mods["creative-mod"] then
    commands.add_command("belt-balancer-test", "", function(e)
        test_mod(e.player_index)
    end)
end

function built_entity(e)
    ---@type LuaEntity
    local entity

    if e.entity then
        entity = e.entity
    else
        entity = e.created_entity
    end

    if entity.name == "balancer-part" then
        part_functions.built(entity)
    end

    if entity.type == "transport-belt" then
        belt_functions.built_belt(entity)
    end

    if entity.type == "underground-belt" then
        belt_functions.built_belt(entity)
    end

    if entity.type == "splitter" then
        belt_functions.built_splitter(entity)
    end
end

script.on_event(
    {
        defines.events.on_built_entity,
        defines.events.on_robot_built_entity,
        defines.events.script_raised_built,
        defines.events.script_raised_revive
    },
    built_entity
)

function remove_entity(e)
    ---@type LuaEntity
    local entity

    if e.entity then
        entity = e.entity
    else
        entity = e.created_entity
    end

    if entity.name == "balancer-part" then
        part_functions.remove(entity, e.buffer)
    end

    if entity.type == "transport-belt" then
        belt_functions.remove_belt(entity)
    end

    if entity.type == "underground-belt" then
        belt_functions.remove_belt(entity)
    end

    if entity.type == "splitter" then
        belt_functions.remove_splitter(entity)
    end
end

script.on_event(
    {
        defines.events.on_entity_died,
        defines.events.on_player_mined_entity,
        defines.events.on_robot_mined_entity,
        defines.events.script_raised_destroy
    },
    remove_entity
)

script.on_event({ defines.events.on_player_rotated_entity },
    function(e)
        if e.entity.type == "transport-belt" then
            belt_functions.remove_belt(e.entity, e.previous_direction)
            belt_functions.built_belt(e.entity)
        end

        if e.entity.type == "underground-belt" then
            belt_functions.remove_belt(e.entity, e.previous_direction)
            belt_functions.built_belt(e.entity)

            -- Neighbour is only the other end
            local neighbour = e.entity.neighbours
            if neighbour and neighbour.valid then
                -- make neighbour also have previous_direction
                local previous_direction = (neighbour.direction + 4) % 8
                belt_functions.remove_belt(neighbour, previous_direction)
                belt_functions.built_belt(neighbour)
            end
        end

        if e.entity.type == "splitter" then
            belt_functions.remove_splitter(e.entity, e.previous_direction)
            belt_functions.built_splitter(e.entity)
        end
    end
)

-- on new savegame and on adding mod to existing save
script.on_init(function()
    global.belt_balancer_max_id = 0

    global.new_balancers = {}
    global.events = {}

    -- Unlock recipes, if technologies already researched
    for _, force in pairs(game.forces) do
        if force.technologies["logistics"].researched then
            force.recipes["belt-balancer-normal-belt"].enabled = true
        end
        if force.technologies["logistics-2"].researched then
            force.recipes["belt-balancer-fast-belt"].enabled = true
        end
        if force.technologies["logistics-3"].researched then
            force.recipes["belt-balancer-express-belt"].enabled = true
        end
    end
end)

-- If some mod is changed, so train-stops are not valid anymore ... also reload
script.on_configuration_changed(
    function(e)
        ---@type ModConfigurationChangedData
        local boblogistics_changes = e.mod_changes["boblogistics"]

        if boblogistics_changes and boblogistics_changes.old_version == nil and boblogistics_changes.new_version and settings.startup["bobmods-logistics-beltoverhaul"].value == true then
            -- on boblogistics got added!
            for _, force in pairs(game.forces) do
                local technologies = force.technologies
                local recipes = force.recipes

                technologies["belt-balancer-0"].researched = technologies["belt-balancer-1"].researched
                recipes["belt-balancer-basic-belt"].enabled = technologies["belt-balancer-1"].researched
            end
        end
    end
)

script.on_load(reregister_on_tick)

commands.add_command("belt-balancer-statistics", "", function(e)
    local balancer_amount = #global.new_balancers
    local balancer_part_amount = 0
    local balancer_input_belt_amount = 0
    local balancer_output_belt_amount = 0

    for _, balancer in pairs(global.new_balancers) do
        balancer_part_amount = balancer_part_amount + table_size(balancer.splitter)
        balancer_input_belt_amount = balancer_input_belt_amount + table_size(balancer.input_belts)
        balancer_output_belt_amount = balancer_output_belt_amount + table_size(balancer.output_belts)
    end

    local output = "balancers: " .. balancer_amount ..
                   "\nbalancer-parts: " .. balancer_part_amount ..
                   "\nbalancer_input_belts: " .. balancer_input_belt_amount ..
                   "\nbalancer_output_belts: " .. balancer_output_belt_amount
    game.get_player(e.player_index).print(output)
    print(output)
end)
