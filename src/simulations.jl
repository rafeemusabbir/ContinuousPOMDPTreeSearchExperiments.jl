abstract type Sim end

struct POMDPSim <: Sim
    simulator::Simulator
    pomdp::POMDP
    policy::Policy
    updater::Updater
    initial_belief::Any
    initial_state::Any
    metadata::Dict{Symbol}
end

struct MDPSim <: Sim
    simulator::Simulator
    mdp::MDP
    policy::Policy
    initial_state::Any
    metadata::Dict{Symbol}
end

"""
    Sim(p::POMDP, policy::Policy, metadata=Dict(:note=>"a note"))
    Sim(p::POMDP, policy::Policy[, updater[, initial_belief[, initial_state]]]; kwargs...)

Create a `Sim` object that represents a POMDP simulation.
"""
function Sim(pomdp::POMDP,
                    policy::Policy,
                    up=updater(policy),
                    initial_belief=initial_state_distribution(pomdp),
                    initial_state=nothing;
                    rng::AbstractRNG=Base.GLOBAL_RNG,
                    max_steps::Int=typemax(Int),
                    simulator::Simulator=HistoryRecorder(rng=rng, max_steps=max_steps),
                    metadata::Dict{Symbol}=Dict{Symbol, Any}()
                   )

    if initial_state == nothing && state_type(pomdp) != Void
        is = rand(rng, initial_belief)
    else
        is = initial_state
    end
    return POMDPSim(simulator, pomdp, policy, up, initial_belief, is, metadata)
end

"""
    Sim(p::MDP, policy::Policy, metadata=Dict(:note=>"a note"))
    Sim(p::MDP, policy::Policy[, initial_state]; kwargs...)

Create a `Sim` object that represents a MDP simulation.

A vector of `Sim` objects can be executed with `run` or `run_parallel`.

## Keyword Arguments
- `rng::AbstractRNG=Base.GLOBAL_RNG`
- `max_steps::Int=typemax(Int)`
- `simulator::Simulator=HistoryRecorder(rng=rng, max_steps=max_steps)`
- `metadata::Dict{Symbol}=Dict{Symbol, Any}()` a dictionary of metadata for the sim that will be recorded, e.g. `Dict(:solver_iterations=>500)`.
"""
function Sim(mdp::MDP,
             policy::Policy,
             initial_state=nothing;
             rng::AbstractRNG=Base.GLOBAL_RNG,
             max_steps::Int=typemax(Int),
             simulator::Simulator=HistoryRecorder(rng=rng, max_steps=max_steps),
             metadata::Dict{Symbol}=Dict{Symbol, Any}()
            )

    if initial_state == nothing && state_type(pomdp) != Void
        is = initial_state(mdp, rng) 
    else
        is = initial_state
    end
    return MDPSim(simulator, mdp, policy, is, metadata)
end

POMDPs.simulate(s::POMDPSim) = simulate(s.simulator, s.pomdp, s.policy, s.updater, s.initial_belief, s.initial_state)
POMDPs.simulate(s::MDPSim) = simulate(s.simulator, s.mdp, s.policy, s.initial_state)

function default_process(s::Sim, r::Float64)
    stuff = metadata_as_pairs(s)
    return push!(stuff, :reward=>r)
end
default_process(s::Sim, hist::SimHistory) = default_process(s, discounted_reward(hist))

metadata_as_pairs(s::Sim) = convert(Array{Any}, collect(s.metadata))

run_parallel(queue::AbstractVector) = run_parallel(default_process, queue)

function run_parallel(process::Function, queue::AbstractVector;
                      progress=Progress(length(queue), desc="Simulating..."))

    #=
    frame_lines = pmap(progress, queue) do sim
        result = simulate(sim)
        return process(sim, result)
    end
    =#

    # based on the simple implementation of pmap here: https://docs.julialang.org/en/latest/manual/parallel-computing
    np = nprocs()
    n = length(queue)
    i = 1
    prog = 0
    frame_lines = Vector{Any}(n)
    nextidx() = (idx=i; i+=1; idx)
    prog_lock = ReentrantLock()
    @sync begin 
        for p in 1:np
            if np == 1 || p != myid()
                @async begin
                    while true
                        idx = nextidx()
                        if idx > n
                            break
                        end
                        frame_lines[idx] = remotecall_fetch(p, queue[idx]) do sim
                            result = simulate(sim)
                            return process(sim, result)
                        end
                        if progress isa Progress
                            lock(prog_lock)
                            update!(progress, prog+=1)
                            unlock(prog_lock)
                        end
                    end
                end
            end
        end
    end

    return create_dataframe(frame_lines)
end

Base.run(queue::AbstractVector) = run(default_process, queue)

function Base.run(process::Function, queue::AbstractVector; show_progress=true)
    lines = []
    if show_progress
        @showprogress for sim in queue
            result = simulate(sim)
            push!(lines, process(sim, result))
        end
    else
        for sim in queue
            result = simulate(sim)
            push!(lines, process(sim, result))
        end
    end
    return create_dataframe(lines)
end

function create_dataframe(lines::Vector)
    master = Dict{Symbol, DataArray}()
    for line in lines
        push_line!(master, line)
    end
    return DataFrame(master)
end

function _push_line!(d::Dict{Symbol, DataArray}, line)
    if isempty(d)
        len = 0
    else
        len = length(first(values(d)))
    end
    for (key, val) in line
        if !haskey(d, key)
            d[key] = DataArray(typeof(val), len)
        end
        data = d[key]
        if !(typeof(val) <: eltype(data))
            d[key] = convert(DataArray{Any,1}, data)
        end
        push!(d[key], val)
    end
    for da in values(d)
        if length(da) < len + 1
            push!(da, NA)
        end
    end
    return d
end
push_line!(d::Dict{Symbol, DataArray}, line::Dict) = _push_line!(d, line)
push_line!(d::Dict{Symbol, DataArray}, line::DataFrame) = _push_line!(d, n=>first(line[n]) for n in names(line))
push_line!(d::Dict{Symbol, DataArray}, line::Vector{Any}) = _push_line!(d, line)
push_line!(d::Dict{Symbol, DataArray}, line::Tuple) = _push_line!(d, line)
