using .BaseAgent
using Params
using Traffic.Simple
using Channel.Gilbert
using Util

export RandomChannel

type RandomChannel <: Agent
    s :: AgentState
    status :: Status
    RandomChannel(i, P) = new(AgentState(i, P))
end

function BaseAgent.act(a :: RandomChannel, env, t)
    if a.status == Initialized
        if a.s.B_max - a.s.B_empty == 0
            return idle(a)
        end

        chan = rand(int8(1):n_channel)
        return switch(a, chan)
    elseif a.status == Switched
        return sense(a, env, detect_traffic)
    elseif a.status == Sensed
        if detect_traffic(env.traffics[a.s.chan], a.s.t_remaining)
            return idle(a)
        else
            P_tx = Params.P_levels[rand(1:endof(Params.P_levels))]
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
