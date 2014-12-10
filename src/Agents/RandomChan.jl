using .BaseAgent
using Params
using Traffic.Simple
using Channel.Gilbert
using Util

export RandomChannel

type RandomChannel <: Agent
    s :: AgentState
    RandomChannel(i) = new(AgentState(i))
end

function BaseAgent.act(a :: RandomChannel, env, t)
    pkgs_to_send = a.s.B_max - a.s.B_empty

    if pkgs_to_send == 0
        return idle(a)
    end

    chan = rand(int8(1):n_channel)
    switch!(a.s, chan)

    if sense(a, env, detect_traffic)
        return idle(a)
    end

    P_tx = Params.P_levels[rand(1:endof(Params.P_levels))]
    pkgs_to_send = min(pkgs_to_send, floor((a.s.t_remaining * capacity(env.channels[a.s.chan], P_tx, a.s.pos)) / Params.pkt_size))

    if pkgs_to_send == 0
        return idle(a)
    end

    transmit!(a.s, P_tx, env, pkgs_to_send)
end
