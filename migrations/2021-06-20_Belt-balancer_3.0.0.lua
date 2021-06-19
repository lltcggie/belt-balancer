for _, balancer in pairs(global.balancer) do
    balancer.next_input = 1
    balancer.next_output = 1
end
