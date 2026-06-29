using JuMP, HiGHS

@testset "solver smoke" begin
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, x >= 0)
    @variable(m, y >= 0)
    @constraint(m, c, x + y >= 10)
    @objective(m, Min, 2x + 3y)
    optimize!(m)
    @test termination_status(m) == MOI.OPTIMAL
    @test isapprox(objective_value(m), 20.0; atol=1e-9)   # all-x solution
    @test isapprox(dual(c), 2.0; atol=1e-9)               # shadow price = cheaper coeff
end
