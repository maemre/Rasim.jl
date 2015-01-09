
using .BaseAgent
using Params
using Traffic.Simple
using Channel.Gilbert
using Util

export CooperativeQ

type CooperativeQ <: Agent
    s :: AgentState
    Q :: Array{Float64, 3}
    visit :: Array{Float64, 3}
    a :: Int
    state :: (Int, Int)
    P_tx :: Float64
    bitrate :: Float64
    status :: Status
    expertness :: Float64
    buf_interval :: Int
    beta_idle :: Float64
end

const n_p_levels = length(Params.P_levels)
const idle_action = Params.n_channel * n_p_levels + 1
const beta_overflow = 1000
const beta_md = 1 # misdetection punishment coefficient
const beta_loss = 2 # punishment for data loss in channel
const epsilon = 0.05 # exploration probability
const discount = 0.2 # discount factor, gamma

function CooperativeQ(i, P)
    Q = rand(int(Params.n_channel), P.buf_levels + 1, idle_action)
    Q *= Params.P_tx * Params.t_slot # a good initial randomization
    visit = zeros(Params.n_channel, P.buf_levels + 1, idle_action)
    CooperativeQ(AgentState(i, P), Q, visit, 0, (0, 0), 0, 0, Initialized, 0, div(Params.B + 1, P.buf_levels), P.beta_idle)
end

function policy!(a :: CooperativeQ)
    # check whether we have packets first
    if rand() < epsilon
        a.a = rand(1:idle_action)
    else
        a.a = indmax(a.Q[a.s.chan, div(a.s.B_empty, a.buf_interval) + 1, :])
    end
    nothing
end

function BaseAgent.act(a :: CooperativeQ, env, t)
    if a.status == Initialized
        if a.s.B_max - a.s.B_empty == 0
            a.a = -1
            return idle(a)
        end

        policy!(a)
        a.state = (a.s.chan, div(a.s.B_empty, a.buf_interval) + 1)
        a.visit[a.s.chan, a.state[2], a.a] += 1

        if a.a == idle_action
            return idle(a)
        end

        chan = int8(fld(a.a - 1, n_p_levels) + 1)
        return switch(a, chan)
    elseif a.status == Switched
        return sense(a, env, detect_traffic)
    elseif a.status == Sensed
        if detect_traffic(env.traffics[a.s.chan], a.s.t_remaining)
            return idle(a)
        else
            a.P_tx = Params.P_levels[(a.a - 1) % n_p_levels + 1]
            a.bitrate = capacity(env.channels[a.s.chan], a.P_tx, a.s.pos)
            pkgs_to_send = min(a.s.B_max - a.s.B_empty, floor(a.s.t_remaining * a.bitrate / Params.pkt_size))

            if pkgs_to_send == 0
                return idle(a)
            end
            return transmit!(a, a.P_tx, env, pkgs_to_send)
        end
    elseif a.status == Transmitted
        return idle(a)
    end
end

function alpha(a :: CooperativeQ)
    return 0.2 + 0.8 / (1 + a.visit[a.state[1], a.state[2], a.a])
end

function BaseAgent.feedback(a :: CooperativeQ, res :: Result, idle :: Bool = false, n_pkt :: Int = 0)
    feedback(a.s, res, idle, n_pkt)
    # if we didn't take any action that's worth learning, return immediately
    if a.a == -1
        return nothing
    end
    r :: Float64 = 0
    if idle
        r = - a.beta_idle * a.s.E_slot
    elseif res == Success
        K = 1 # a.P_tx ^ 2 * Params.t_slot / a.bitrate
        r = K * Params.pkt_size * n_pkt / a.s.E_slot
    elseif res == Collision
        r = - beta_md * a.bitrate * Params.t_slot / a.s.E_slot
    elseif res == LostInChannel
        r = - beta_loss * a.bitrate * Params.t_slot / a.s.E_slot
    else
        return nothing
    end
    # UPDATE Q
    max_Q_next = maximum(a.Q[a.s.chan, floor(a.s.B_empty / a.buf_interval) + 1])
    Q_now = a.Q[a.state[1], a.state[2], a.a]
    a.Q[a.state[1], a.state[2], a.a] += alpha(a) * (r + discount * max_Q_next - Q_now)
    # Update expertness
    if r > 0
        a.expertness += r # sum of reinforcements for now
    end
    nothing
end