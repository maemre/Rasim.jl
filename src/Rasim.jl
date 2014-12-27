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
    pkt_sent = zeros(Int, n_agent)
    rawtimeQ = 0
    interference = zeros(n_channel, n_agent)
    release_time = zeros(n_channel)

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
            fill!(release_time, 0)

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
            actions = [Event(Params.t_slot - a.s.t_remaining, initial_action(a, env, t)) for a in agents]
            heapify!(actions)
            # save initial statistics
            trajectories[t, :] = [a.s.pos for a in agents]
            @simd for i=1:n_agent
                @inbounds buf_overflow[n_run, i, t] = agents[i].s.buf_overflow
                @inbounds buf_levels[n_run, i, t] = B - agents[i].s.B_empty
            end

            if n_agent > 1 && AgentT == CooperativeQ
                # join Cooperative Q learners
                if t > Params.t_saturation && t % Params.sharingperiod < 2 * Params.n_agent * Params.timeQ
                    tt = t % Params.sharingperiod
                    i = fld(tt, Params.timeQ) + 1
                    # sending phase (from CR)
                    if tt < Params.n_agent * Params.timeQ
                        # receiving complete, update combined Q matrix
                        # using only positive expertness ones
                        if tt - (i-1) * Params.timeQ == Params.timeQ - 1
                            Q[i,:,:,:] = agents[i].expertness .* agents[i].Q
                            expertness[i] = agents[i].expertness
                        end
                        if tt == (i - 1) * Params.timeQ
                            # initialize control channel usage overhead
                            rawtimeQ = Params.rawtimeQ
                        end
                        # Calculate control channel energy overhead
                        if rawtimeQ > 1
                            agents[i].s.E_slot += Params.P_tx * t_slot # add control channel energy overhead
                        else
                            agents[i].s.E_slot += Params.P_tx * t_slot * rawtimeQ # add control channel energy overhead
                        end
                        rawtimeQ -= 1 # doesn't matter when rawtimeQ < 1, it'll be reset anyways
                    else # receiving phase (to CR)
                        i -= n_agent
                        # sending complete, update agent's Q matrix
                        if tt - (i+n_agent-1) * Params.timeQ == Params.timeQ - 1
                            #fill!(agents[i].Q, 0)
                            # use up-to-date Q function on CR's side
                            weight = 1 - Params.trustQ
                            agents[i].Q *= weight #* reshape(Q[j,:,:,:], size(agents[i].Q))
                            # learning from experts (LE)
                            # choose some experts randomly
                            experts = zeros(Bool, n_agent)
                            for e in shuffle!([[x for x=1:i-1],[x for x=i+1:n_agent]])[1:fld(n_agent, 2)]
                                experts[e] = true
                            end
                            for j=1:n_agent
                                if i == j
                                    continue
                                elseif !experts[j]
                                    continue
                                else
                                    if expertness[j] > expertness[i]
                                        weight = Params.trustQ * (expertness[j] - expertness[i])
                                        # normalize
                                        weight ./= sum((expertness - expertness[i]) .* (expertness .> expertness[i]))
                                    agents[i].Q += weight * reshape(Q[j,:,:,:], size(agents[i].Q))
                                    end
                                end
                            end
                            agents[i].expertness = 0 # *= 1 - Params.trustQ
                        end
                    end
                end
            end

            # interpret actions
            last_actions = Array(Action, Params.n_agent)
            # whether agents[i] has collided
            collided = zeros(Bool, n_agent)
            # resolve all actions
            fill!(pkt_sent, 0)
            while ! isempty(actions)
                event = heappop!(actions)
                action = event.a
                tt = event.t
                a = agents[action.i]
                if isa(action, Switch)
                    switch!(agents[action.i], action.chan)
                    heappush!(actions, Event(Params.t_slot - a.s.t_remaining, act(a, env, t)))
                    last_actions[action.i] = action
                elseif isa(action, Sense)
                    heappush!(actions, Event(Params.t_slot - a.s.t_remaining, act(a, env, t)))
                    last_actions[action.i] = action
                elseif isa(action, Transmit)
                    i = action.chan
                    traffics[i].occupancy = min(tt, traffics[i].occupancy)
                    # add interference
                    interfere!(channels[i], action.power, agents[action.i].s.pos)
                    interference[i, :] = max(interference[i, :], channels[i].interference)
                    # keep current interference
                    interference[i, action.i] = channels[i].interference
                    # use previous occupier data to mark as collided
                    if traffics[i].occupier > -1 && traffics[i].occupier != action.i
                        if traffics[i].occupier > 0
                            collided[traffics[i].occupier] = true # also mark the occupier
                            if release_time[i] > tt
                                collided[action.i] = true
                            end
                        else
                            collided[action.i] = true
                        end
                    end
                    if traffics[i].occupier != 0
                        # mark self as occupier
                        traffics[i].occupier = action.i
                    end
                    release_time[i] = max(release_time[i], tt + Params.pkt_size / action.bitrate)
                    # Enqueue end of this transmission
                    heappush!(actions, Event(Params.t_slot - a.s.t_remaining, EndTransmission(action)))
                    last_actions[action.i] = action
                elseif isa(action, EndTransmission)
                    #= 
                    Remove interference. Order of this is important, o/w we'll interpret
                    our signal as part of interference.
                    =#
                    prev_interference = channels[action.chan].interference
                    interfere!(channels[action.chan], - action.power, a.s.pos)
                    tmp = channels[action.chan].interference
                    # change channel interference for us, then bring it back
                    channels[action.chan].interference = interference[action.chan, action.i] - (prev_interference - tmp)
                    # if no PU collision
                    if ! traffics[i].traffic
                        # Resolve transmission result
                        pkt_sent[action.i] += transmission_successes(channels[action.chan], action.power, action.bitrate, a.s.pos.x, a.s.pos.y)
                    end
                    # bring interference back
                    channels[action.chan].interference = tmp
                    # Enqueue next action
                    if action.n_pkt > 1
                        heappush!(actions, Event(Params.t_slot - a.s.t_remaining, Transmit(action)))
                    else
                        heappush!(actions, Event(Params.t_slot - a.s.t_remaining, act(a, env, t)))
                    end
                else # Idle case
                    if !(isdefined(last_actions, int(action.i)) && isa(last_actions[action.i], Transmit))
                        last_actions[action.i] = action
                    end
                end
            end

            # resolve collisions
            for i=1:n_agent
                if isa(last_actions[i], Transmit)
                    transmissions[n_run, i, t] = last_actions[i].chan
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
        if !isinteractive()
            plot_ee(avg_energies, avg_bits, string(AgentT), at_no)
        end
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
