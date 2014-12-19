#!/usr/bin/env julia

module Rasim

if !isinteractive()
    print("Loading modules... ")
end

using Params
using Agents.BaseAgent
using Agents
using Traffic.Simple
using Channel.Gilbert
using HDF5, JLD
using Movement
using Plots
using Base.Collections


if !isinteractive()
    println("DONE!")
end

output_dir = joinpath("data/", prefix)

if !isdir(output_dir)
    mkpath(output_dir, 0o755)
end

const goodness = shuffle!(append!(2 * ones(Int, n_good_channel), ones(Int, n_channel - n_good_channel)))
const agent_types = [CooperativeQ, RandomChannel, IndividualQ, OptHighestSNR]

# generate ith channel
function genchan(i)
    GilbertChannel(base_freq + chan_bw * i, noise[goodness[i], :], chan_trans_prob)
end

function run_simulation(AgentT, at_no :: Int)
    avg_energies = zeros(n_agent, t_total)
    avg_bits = zeros(n_agent, t_total)
    en_idle = zeros(n_agent, t_total)
    en_sense = zeros(n_agent, t_total)
    en_sw = zeros(n_agent, t_total)
    en_tx = zeros(n_agent, t_total)
    buf_overflow = zeros(Bool, n_runs, n_agent, t_total)
    buf_levels = zeros(Int16, n_runs, n_agent, t_total)
    init_positions = Array(Point{Float64}, n_runs, n_agent)
    last_positions = Array(Point{Float64}, n_runs, n_agent)
    trajectories = Array(Point{Float64}, t_total, n_agent) # trajectories for a single run
    transmissions = zeros(n_runs, n_agent, t_total) # channels tried for transmission
    channel_traf = zeros(Int8, n_channel, n_runs, t_total)
    Q = zeros(n_agent, int(Params.n_channel), Params.buf_levels + 1, Params.n_channel * length(Params.P_levels) + 1)
    expertness = zeros(n_agent)

    channels = [genchan(i) for i=1:n_channel]
    traffics = [SimpleTraffic() for i=1:n_channel]
    env = Environment(channels, traffics)

    println("Agent type: ", AgentT)

    for n_run=1:n_runs
        agents = [AgentT(i) for i::Int8=1:n_agent]
        init_positions[n_run, :] = [a.s.pos for a in agents]
        energies = zeros(n_agent, t_total)
        bits = zeros(n_agent, t_total)
        if verbose
            @printf("Run %d of %d (agent), %d of %d (total)\n", n_run, n_runs, n_run + (at_no - 1) * n_runs, length(agent_types) * n_runs)
        end

        rates = zeros(5)

        for t=1:t_total
            # iterate environment
            for c in channels
                iterate(c)
            end
            for traf in traffics
                Simple.iterate(traf)
            end

            # get initial actions
            actions = PriorityQueue{Action, Float64}()
            for a in agents
                time = Params.t_slot - a.s.t_remaining
                enqueue!(actions, initial_action(a, env, t), time)
            end
            # save initial statistics
            trajectories[t, :] = [a.s.pos for a in agents]
            @simd for i=1:n_agent
                @inbounds buf_overflow[n_run, i, t] = agents[i].s.buf_overflow
                @inbounds buf_levels[n_run, i, t] = B - agents[i].s.B_empty
            end

            if AgentT == CooperativeQ
                # join Cooperative Q learners
                if t > Params.t_saturation && t % Params.sharingperiod < 2 * Params.n_agent * Params.timeQ
                    tt = t % Params.sharingperiod
                    i = fld(tt, Params.timeQ) + 1
                    if tt < Params.n_agent * Params.timeQ
                        # receiving complete, update combined Q matrix
                        # using only positive expertness ones
                        if tt - (i-1) * Params.timeQ == Params.timeQ - 1
                            Q[i,:,:,:] = agents[i].expertness .* agents[i].Q
                            expertness[i] = agents[i].expertness
                        end
                    else
                        i -= n_agent
                        # sending complete, update agent's Q matrix
                        if tt - (i+n_agent-1) * Params.timeQ == Params.timeQ - 1
                            fill!(agents[i].Q, 0)
                            # learning from experts (LE)
                            # choose some experts randomly
                            experts = zeros(Bool, n_agent)
                            for e in shuffle!([[x for x=1:i-1],[x for x=i+1:n_agent]])[1:fld(n_agent, 2)]
                                experts[e] = true
                            end
                            for j=1:n_agent
                                if i == j
                                    weight = 1 - Params.trustQ
                                elseif !experts[j]
                                    continue
                                else
                                    if expertness[j] > expertness[i]
                                        weight = Params.trustQ * (expertness[j] - expertness[i])
                                        # normalize
                                        weight ./= sum((expertness - expertness[i]) .* (experts & (expertness .> expertness[i])))
                                    else
                                        continue
                                    end
                                end
                                agents[i].Q += weight * reshape(Q[j,:,:,:], size(agents[i].Q))
                            end
                            agents[i].expertness = 0.
                        end
                    end
                    #agents[i].s.E_slot += Params.P_tx * t_slot # add control channel energy overhead
                end
            end

            last_actions = Array(Action, Params.n_agent)
            # whether agents[i] has collided
            collided = zeros(Bool, n_agent)
            # resolve all actions
            while ! isempty(actions)
                action, tt = peek(actions)
                a = agents[action.i]
                dequeue!(actions)
                if isa(action, Switch)
                    switch!(agents[action.i], action.chan)
                    enqueue!(actions, act(a, env, t), Params.t_slot - a.s.t_remaining)
                elseif isa(action, Sense)
                    enqueue!(actions, act(a, env, t), Params.t_slot - a.s.t_remaining)
                elseif isa(action, Transmit)
                    i = action.chan
                    traffics[i].occupancy = min(tt, traffics[i].occupancy)
                    # use first occupier data to mark as collided
                    if traffics[i].occupier > -1
                        collided[action.i] = true
                        if traffics[i].occupier > 0
                            collided[traffics[i].occupier] = true # I'm the first occupier
                        end
                    else
                        traffics[i].occupier = action.i
                    end
                    enqueue!(actions, act(a, env, t), Params.t_slot - a.s.t_remaining)
                end
                if ! (isa(action, Idle) && isdefined(last_actions, int(action.i)) && isa(last_actions[action.i], Transmit))
                    last_actions[action.i] = action
                end
            end

            # resolve collisions
            for i=1:n_agent
                if isa(last_actions[i], Transmit)
                    if ! collided[i]
                        transmissions[n_run, i, t] = last_actions[i].chan
                    end
                else
                    transmissions[n_run, i, t] = 0
                end
            end

            for i=1:n_agent
                a = agents[i]
                energies[i, t] = a.s.E_slot
                en_idle[i, t] += a.s.E_idle
                en_sense[i, t] += a.s.E_sense
                en_tx[i, t] += a.s.E_tx
                en_sw[i, t] += a.s.E_sw
                act = last_actions[i]

                if isa(act, Idle)
                    feedback(agents[i], Success, true)
                    rates[4] += 1
                    continue
                elseif collided[i]
                    feedback(agents[i], Collision)
                    rates[1] += 1
                    # count PU collisions
                    if traffics[act.chan].occupier == 0
                        rates[5] += 1
                    end
                    continue
                elseif isa(act, Transmit)
                    ch = channels[act.chan]
                    pkt_sent = transmission_successes(ch, act.power, act.bitrate, act.n_pkt, a.s.pos.x, a.s.pos.y)
                    
                    if pkt_sent == 0
                        feedback(agents[i], LostInChannel)
                    else
                        feedback(agents[i], Success, false, pkt_sent)
                    end

                    rates[2] += pkt_sent / act.n_pkt
                    rates[3] += act.n_pkt - pkt_sent
                    # collect bit transmission statistics
                    bits[i, t] = pkt_sent * Params.pkt_size
                end
            end
        end

        avg_energies += energies
        avg_bits += bits

        rates[5] /= t_total * n_channel / 100
        last_positions[n_run, :] = [a.s.pos for a in agents]

        if verbose
            println("Collisions: ", rates[1])
            println("Successes: ", rates[2])
            println("Lost in Channel: ", rates[3])
            println("Idle: ", rates[4])
            println("%PU Collisions: ", rates[5])
            println("Success: %", rates[2]/(t_total * n_agent - rates[4]) * 100)
            println("Collided Channels: %", rates[1]/(t_total * n_channel) * 100, "\n")
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
        plot_ee(avg_energies, avg_bits, string(AgentT), at_no)
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

    @save joinpath(output_dir, string(AgentT, ".jld")) avg_energies avg_bits en_idle en_sense en_sw en_tx buf_overflow buf_levels init_positions last_positions trajectories transmissions channel_traf
end

if !isinteractive()
    if verbose
        initplots()
    end
    for i=1:endof(agent_types)
        run_simulation(agent_types[i], i)
    end
    if verbose
        displayplots()
        readline()
    end
end

end # module
