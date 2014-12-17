#!/usr/bin/env julia

module Rasim

if !isinteractive()
    print("Loading modules...")
end

using Params
using Agents.BaseAgent
using Agents
using Traffic.Simple
using Channel.Gilbert
using HDF5, JLD
using Movement
using Plots


if !isinteractive()
    println("DONE!")
end

output_dir = joinpath("data/", prefix)

if !isdir(output_dir)
    mkpath(output_dir, 0o755)
end

const goodness = shuffle!(append!(2 * ones(Int, n_good_channel), ones(Int, n_channel - n_good_channel)))
const agent_types = [RandomChannel, IndividualQ, OptHighestSNR]

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
            # get actions
            actions = [act_then_idle(a, env, t) for a in agents]
            # save initial statistics
            trajectories[t, :] = [a.s.pos for a in agents]
            @simd for i=1:n_agent
                @inbounds buf_overflow[n_run, i, t] = agents[i].s.buf_overflow
                @inbounds buf_levels[n_run, i, t] = B - agents[i].s.B_empty
            end

            # collisions per channel where,
            # -1: PU collision, (1..N_agent): SU collision with ID
            # 0: No collision
            collisions = [(t.traffic ? -1 : 0) for t in traffics]
            # whether agents[i] has collided
            collided = zeros(Bool, n_agent)
            # resolve collisions
            for i=1:n_agent
                a=actions[i]
                if a == Idle()
                    transmissions[n_run, i, t] = 0
                elseif isa(a, Transmit)
                    if collisions[a.chan] == -1
                        # collision with PU, mark agent as collided
                        collided[i] = true
                        rates[5] += 1
                    elseif collisions[a.chan] > 0
                        # collision with other SU, mark both as collided
                        collided[i] = collided[collisions[a.chan]] = true
                    else
                        # no collisions *yet*, register current agent as occupier
                        collisions[a.chan] = i
                    end
                    transmissions[n_run, i, t] = a.chan
                end
            end

            for i=1:n_agent
                a = agents[i]
                energies[i, t] = a.s.E_slot
                en_idle[i, t] += a.s.E_idle
                en_sense[i, t] += a.s.E_sense
                en_tx[i, t] += a.s.E_tx
                en_sw[i, t] += a.s.E_sw
                act = actions[i]

                if act == Idle()
                    feedback(agents[i], Success, true)
                    rates[4] += 1
                    continue
                elseif collided[i]
                    feedback(agents[i], Collision)
                    rates[1] += 1
                    continue
                end

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
