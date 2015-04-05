using .BaseAgent
using Params
using Traffic.Simple
using Channel.Gilbert
using Util

export OptHighestSNR

type OptHighestSNR <: Agent
    s :: AgentState
    status :: Status
    OptHighestSNR(i, P) = new(AgentState(i, P), Initialized)
end

#=
I written my own minumum that returns Inf instead of
throwing an error when there is no suitable channel to
prevent unnecessary exception checking and performance
drop.
=#
function minimum_noise(env :: Environment)
    min_noise = Inf
    for i=1:endof(env.channels)
        if env.traffics[i].traffic
            continue
        end
        min_noise = min(min_noise, env.channels[i].noise)
    end
    min_noise
end

function BaseAgent.act(a :: OptHighestSNR, env, t)
    if a.status == Initialized
        if a.s.B_max - a.s.B_empty == 0
            return idle(a)
        end

        # we've done packet checking
        min_noise = minimum_noise(env)
        if min_noise == Inf
            return idle(a)
        end

        min_noise_channels = filter(i -> ! env.traffics[i].traffic && env.channels[i].noise <= min_noise, 1:Params.n_channel)
        chan = int8(min_noise_channels[rand(int8(1):endof(min_noise_channels))])

        return switch(a, chan)
    elseif a.status == Switched
        return sense(a, env, detect_traffic)
    elseif a.status == Sensed
        if detect_traffic(a.s, env.traffics[a.s.chan], a.s.t_remaining)
            return idle(a)
        else
            P_tx = Params.P_levels[end-1]
            pkgs_to_send = min(a.s.B_max - a.s.B_empty, floor((a.s.t_remaining * capacity(env.channels[a.s.chan], P_tx, a.s.pos)) / Params.pkt_size))

            if pkgs_to_send == 0
                return idle(a)
            end
            return transmit!(a, P_tx, env, pkgs_to_send)
        end
    elseif a.status == Transmitted
        return idle(a)
    end
end
