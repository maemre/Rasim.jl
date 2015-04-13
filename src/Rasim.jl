#!/usr/bin/env julia

module Rasim

if !isinteractive()
    print("Loading modules... ")
end

using Params
using Agents.BaseAgent
using Agents
using Agents.ContextAware
using Traffic.Simple
using Channel.Gilbert
using HDF5
using JLD
using Movement

if verbose
    using Plots
end

using Base.Collections
using Util

type Event
    t :: Float64
    a :: Action
end

# I'd define Base.<, but it was giving me all sorts of errors
Base.isless(e1 :: Event, e2 :: Event) = e1.t < e2.t # generated code for < is shorter for Floats

if !isinteractive()
    println("DONE!")
end

const agent_types = [OptHighestSNR, CooperativeQ, RandomChannel, ContextQ]

# generate ith channel
function genchan(i, P)
    goodness = shuffle!(append!(2 * ones(Int, P.n_good_channel), ones(Int, n_channel - P.n_good_channel)))
    GilbertChannel(base_freq + chan_bw * i, noise[goodness[i], :], chan_trans_prob)
end

function run_simulation{AgentT <: Agent}(:: Type{AgentT}, at_no :: Int, P :: ParamT, init_positions :: Array{Point{Float64}, 2})
    const output_dir = joinpath("data/", P.prefix)
    const n_agent = int(P.n_agent)
    const sharingperiod = P.sharingperiod
    # size of Q matrix, used for data sharing computation
    const sizeQ = Params.d_svd * 64 * (n_channel * (P.buf_levels + 1) + (n_channel * length(P_levels) + 1))
    # time slots required for an agent to send/receive Q matrix
    const timeQ = int(ceil(sizeQ ./ Params.controlcapacity ./ t_slot))
    # time required for an agent to send/receive Q matrix
    const rawtimeQ0 = sizeQ ./ Params.controlcapacity ./ t_slot
    avg_energies = zeros(n_agent, t_total)
    avg_bits = zeros(n_agent, t_total)
    en_idle = zeros(n_agent, t_total)
    en_sense = zeros(n_agent, t_total)
    en_sw = zeros(n_agent, t_total)
    en_tx = zeros(n_agent, t_total)
    buf_overflow = falses(n_runs, n_agent, t_total)
    buf_levels = zeros(Int16, n_runs, n_agent, t_total)
    trajectories = Array(Point{Float64}, t_total, n_agent) # trajectories for a single run
    transmission_channels = zeros(Int8, n_runs, n_agent, t_total) # channels tried for transmission
    # Q = zeros(n_agent, int(Params.n_channel), P.buf_levels + 1, Params.n_channel * length(Params.P_levels) + 1)
    expertness = zeros(n_agent)
    pkt_sent = zeros(Int, n_agent)
    rawtimeQ = 0
    interference = zeros(n_agent, n_channel)
    release_time = zeros(n_channel)
    generated_packets = zeros(Int64, n_agent, n_runs)
    tried_packets = zeros(Int64, n_agent, n_runs)
    sent_packets = zeros(Int64, n_agent, n_runs)
    init_distances = zeros(Float64, n_agent)
    final_distances = zeros(Float64, n_agent)

    channels = [genchan(i, P) for i=1:n_channel]
    traffics = [SimpleTraffic() for i=1:n_channel]
    env = Environment(channels, traffics)
    # coordinator for cooperative Q learning type of agents
    coordinator = initcoordinator(AgentT, P)

    println("Agent type: ", AgentT, " - ", P.iteration)

    for n_run=1:n_runs
        agents = [AgentT(i, P, init_positions[n_run, i]) for i::Int8=1:n_agent]
        energies = zeros(n_agent, t_total)
        bits = zeros(n_agent, t_total)
        if verbose
            @printf("Run %d of %d (agent), %d of %d (total)\n", n_run, n_runs, n_run + (at_no - 1) * n_runs, length(agent_types) * n_runs)
        end

        rates = zeros(5)

        for a=agents
            init_distances[a.s.id] += (a.s.pos.x .^ 2 + a.s.pos.y .^ 2)
        end

        for t=1:t_total
            # iterate environment
            fill!(release_time, 0.)

            for traf in traffics
                iterate(traf)
            end
            
            for i=1:endof(channels)
                iterate!(channels[i])
                if traffics[i].traffic
                    # add interference from a stationary PU, we may change this in the future
                    interfere!(channels[i], Params.P_tx, Point(Params.r_init / 2, 0.))
                end
            end

            # get initial actions
            actions = [Event(Params.t_slot - a.s.t_remaining, initial_action(a, env, t, P)) for a in agents]
            heapify!(actions)
            # save initial statistics
            @inbounds trajectories[t, :] = [a.s.pos for a in agents]
            @simd for i=1:n_agent
                @inbounds buf_overflow[n_run, i, t] = agents[i].s.buf_overflow
                @inbounds buf_levels[n_run, i, t] = B - agents[i].s.B_empty
            end
            @inbounds generated_packets[:, n_run] += buf_levels[n_run, :, t]'
            if t > 1
                @inbounds generated_packets[:, n_run] -= buf_levels[n_run, :, t - 1]'
            end

            cooperate(agents, P, coordinator, t)

            # interpret actions
            last_actions = Array(Action, n_agent)
            # whether agents[i] has collided
            collided = zeros(Bool, n_agent)
            # resolve all actions
            fill!(pkt_sent, 0)
            @inbounds begin
                while ! isempty(actions)
                    const event = heappop!(actions)
                    const action = event.a
                    const tt = event.t
                    const agentid = int(action.i)
                    a = agents[agentid]
                    if isa(action, Switch)
                        switch!(agents[agentid], action.chan)
                        heappush!(actions, Event(Params.t_slot - a.s.t_remaining, act(a, env, t)))
                        last_actions[agentid] = action
                    elseif isa(action, Sense)
                        heappush!(actions, Event(Params.t_slot - a.s.t_remaining, act(a, env, t)))
                        last_actions[agentid] = action
                    elseif isa(action, Transmit)
                        i = int(action.chan)
                        traffics[i].occupancy = min(tt, traffics[i].occupancy)
                        # add interference
                        interfere!(channels[i], action.power, a.s.pos)
                        interference[:, i] = max(interference[:, i], channels[i].interference)
                        # keep current interference
                        interference[agentid, i] = channels[i].interference
                        # use previous occupier data to mark as collided
                        if traffics[i].occupier > -1 && traffics[i].occupier != agentid
                            if traffics[i].occupier > 0
                                collided[traffics[i].occupier] = true # also mark the occupier
                                if release_time[i] > tt
                                    collided[agentid] = true
                                end
                            else
                                collided[agentid] = true
                            end
                        end
                        if traffics[i].occupier != 0
                            # mark self as occupier
                            traffics[i].occupier = agentid
                        end
                        release_time[i] = max(release_time[i], tt + Params.pkt_size / action.bitrate)
                        # Enqueue end of this transmission
                        heappush!(actions, Event(Params.t_slot - a.s.t_remaining, EndTransmission(action)))
                        last_actions[agentid] = action
                    elseif isa(action, EndTransmission)
                        #= 
                        Remove interference. Order of this is important, o/w we'll interpret
                        our signal as part of interference.
                        =#
                        prev_interference = channels[action.chan].interference
                        interfere!(channels[action.chan], - action.power, a.s.pos)
                        tmp = channels[action.chan].interference
                        # change channel interference for us, then bring it back
                        channels[action.chan].interference = interference[agentid, action.chan] - (prev_interference - tmp)
                        # if no PU collision
                        if ! traffics[i].traffic
                            # Resolve transmission result
                            pkt_sent[agentid] += transmission_successes(channels[action.chan], action.power, action.bitrate, a.s.pos.x, a.s.pos.y)
                        end
                        # bring interference back
                        channels[action.chan].interference = tmp
                        # Enqueue next action
                        if action.n_pkt > 1
                            heappush!(actions, Event(Params.t_slot - a.s.t_remaining, Transmit(action)))
                        else
                            heappush!(actions, Event(Params.t_slot - a.s.t_remaining, act(a, env, t)))
                        end
                        # collect statistics
                        tried_packets[agentid, n_run] += 1
                    else # Idle case
                        if !(isdefined(last_actions, int(agentid)) && isa(last_actions[agentid], Transmit))
                            last_actions[agentid] = action
                        end
                    end
                end
            end

            # collect packet statistics
            sent_packets[:, n_run] += pkt_sent

            # resolve collisions
            for i=1:n_agent
                if isa(last_actions[i], Transmit)
                    transmission_channels[n_run, i, t] = int8(last_actions[i].chan)
                else
                    transmission_channels[n_run, i, t] = int8(0)
                end
            end

            @simd for i=1:n_agent
                @inbounds s = agents[i].s
                @inbounds energies[i, t] = s.E_slot
                @inbounds en_idle[i, t] += s.E_idle
                @inbounds en_sense[i, t] += s.E_sense
                @inbounds en_tx[i, t] += s.E_tx
                @inbounds en_sw[i, t] += s.E_sw
            end

            for i=1:n_agent
                a = agents[i]
                act = last_actions[i]

                if isa(act, Idle)
                    feedback(agents[i], Success, true)
                    rates[4] += 1
                    continue
                elseif collided[i]
                    # interference-based collision scheme for SUs
                    # collision with PU
                    if traffics[act.chan].traffic
                        rates[5] += 1
                        rates[1] += 1
                        feedback(agents[i], Collision)
                    else
                        # Complete SU Collision
                        if pkt_sent[i] == 0
                            feedback(agents[i], Collision)
                            rates[1] += 1
                        else
                            # We did sent some packages, albeit collision
                            feedback(agents[i], Success, false, pkt_sent[i])
                            rates[2] += pkt_sent[i] / a.s.n_pkt_slot
                            rates[3] += (a.s.n_pkt_slot - pkt_sent[i]) / a.s.n_pkt_slot
                            # collect bit transmission statistics
                            bits[i, t] = pkt_sent[i] * Params.pkt_size
                        end
                    end
                elseif isa(act, Transmit)
                    ch = channels[act.chan]
                    
                    if pkt_sent[i] == 0
                        feedback(agents[i], LostInChannel)
                    else
                        feedback(agents[i], Success, false, pkt_sent[i])
                    end

                    rates[2] += pkt_sent[i] / a.s.n_pkt_slot
                    rates[3] += (a.s.n_pkt_slot - pkt_sent[i]) / a.s.n_pkt_slot
                    # collect bit transmission statistics
                    bits[i, t] = pkt_sent[i] * Params.pkt_size
                end
            end
        end

        avg_energies += energies
        avg_bits += bits

        rates[5] /= t_total * n_channel / 100

        if verbose
            println("Collisions: ", rates[1])
            println("Successes: ", rates[2])
            println("Lost in Channel: ", rates[3])
            println("Idle: ", rates[4])
            println("%PU Collisions: ", rates[5])
            println("Success: %", rates[2]/(t_total * n_agent - rates[4]) * 100)
            println("Collided Channels: %", rates[1]/(t_total * n_channel) * 100, "\n")
        end

        for a=agents
            final_distances[a.s.id] += (a.s.pos.x .^ 2 + a.s.pos.y .^ 2)
        end
    end
    avg_energies /= n_runs
    avg_bits /= n_runs
    en_idle /= n_runs
    en_sense /= n_runs
    en_tx /= n_runs
    en_sw /= n_runs
    if verbose
        println("Throughput: ", sum(avg_bits))
        println("Efficiency: ", sum(avg_bits)/sum(avg_energies))
        if !isinteractive()
            plot_ee(avg_energies, avg_bits, string(AgentT), at_no)
            plot_buf(reshape(mean(buf_levels, 1), size(buf_levels)[2:end]), string(AgentT), at_no)
        end

        if Params.debug
            println("Energies")
            println(cumsum(sum(avg_energies, 1), 2))
            println("Bits")
            println(cumsum(sum(avg_bits, 1), 2))
            println("Efficiency")
            println(cumsum(sum(avg_energies, 1), 2) ./ cumsum(sum(avg_bits, 1), 2))
            readline()
        end
    end
    avg_buf_levels = mean(buf_levels)
    avg_buf_overflows = mean(buf_overflow)
    buf_matrix = reshape(mean(buf_levels, 1), size(buf_levels)[2:end])
    @save joinpath(output_dir, string(AgentT, ".jld")) buf_matrix avg_energies avg_bits avg_buf_levels avg_buf_overflows generated_packets tried_packets sent_packets
    @save joinpath(output_dir, string(AgentT, "-extra.jld")) init_positions init_distances final_distances
    #@save "trajectories.jld" trajectories
end

function run_whole_simulation(P :: ParamT)
    output_dir = joinpath("data/", P.prefix)

    if !isdir(output_dir)
        mkpath(output_dir, 0o755)
    end
    
    if verbose
        initplots()
    end

    # Generate same initial positions among all agent types
    positions = Array(Point{Float64}, Params.n_runs, P.n_agent)
    for i=1:Params.n_runs, j=1:P.n_agent
        r = sqrt(rand()) * Params.r_init
        theta = rand()*2*pi
        positions[i, j] = Point(r * cos(theta), r * sin(theta))
    end

    for i=1:endof(agent_types)
        run_simulation(agent_types[i], i, P, positions)
    end
    if verbose
        displayplots()
        readline()
    end
    println("DONE ", P.iteration)
    nothing
end

end # module
