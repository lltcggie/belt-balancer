local function convert_lane_table(tab)
    local new_tab = {}
    for _, lane_index in pairs(tab) do
        table.insert(new_tab, lane_index)
    end
    return new_tab
end

-- convert
for _, part in pairs(global.parts) do
    --part.input_belts = convert_lane_table(part.input_belts)
    --part.output_belts = convert_lane_table(part.output_belts)
    part.input_lanes = convert_lane_table(part.input_lanes)
    part.output_lanes = convert_lane_table(part.output_lanes)
end

for _, balancer in pairs(global.balancer) do
    balancer.input_lanes = convert_lane_table(balancer.input_lanes)
    balancer.output_lanes = convert_lane_table(balancer.output_lanes)
end
