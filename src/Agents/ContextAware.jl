module ContextAware

using Agents.BaseAgent
using Params
using Traffic.Simple
using Channel.Gilbert
using Util
using Params.QParams

export ContextQ

# Q-Learning state, may contains some fields in
# AgentState
type StateT
    chan :: Int
    buflevel :: Int
    energysaving :: EnergySavingMode
end

type ContextQ <: Agent
    s :: AgentState
    Q :: Array{Float64, 4}
    visit :: Array{Float64, 4}
    a :: Int
    P_tx :: Float64
    bitrate :: Float64
    status :: Status
    expertness :: Float64
    buf_interval :: Int
    beta_idle :: Float64
    state :: StateT
    δ :: Float64
    trustQ :: Float64
    buflevels :: Int # needed for bufer-level-baed computation in feedback
end

const n_p_levels = length(Params.P_levels)
const idle_action = Params.n_channel * n_p_levels + 1

function ContextQ(i, P, pos)
    Q = rand(EnergySaving.n, int(Params.n_channel), P.buf_levels + 1, idle_action)
    Q *= Params.P_tx * Params.t_slot # a good initial randomization
    visit = zeros(Int, EnergySaving.n, Params.n_channel, P.buf_levels + 1, idle_action)
    agent = ContextQ(AgentState(i, P, pos), Q, visit, 0, 0, 0, Initialized, 0, div(Params.B + 1, P.buf_levels), P.beta_idle, StateT(0, 0, MaxThroughput), P.δ, P.trustQ, P.buf_levels + 1)
    agent.state.energysaving = agent.s.energysaving
    agent
end

function policy!(a :: ContextQ)
    if rand() < epsilon
        a.a = rand(1:idle_action)
    else
        a.a = indmax(a.Q[a.state.energysaving.n, a.s.chan, div(a.s.B_empty, a.buf_interval) + 1, :])
    end
    nothing
end

function BaseAgent.act(a :: ContextQ, env, t)
    # check whether we have packets first
    if a.status == Initialized
        if a.s.B_max - a.s.B_empty == 0
            a.a = -1
            return idle(a)
        end

        policy!(a)
        # infer state
        a.state.chan = a.s.chan
        a.state.buflevel = div(a.s.B_empty, a.buf_interval) + 1
        a.state.energysaving = a.s.energysaving
        # update state visit count
        a.visit[a.state.energysaving.n, a.state.chan, a.state.buflevel, a.a] += 1

        if a.a == idle_action
            return idle(a)
        end

        chan = int8(fld(a.a - 1, n_p_levels) + 1)
        return switch(a, chan)
    elseif a.status == Switched
        return sense(a, env, detect_traffic)
    elseif a.status == Sensed
        if detect_traffic(a.s, env.traffics[a.s.chan], a.s.t_remaining)
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

function alpha(a :: ContextQ)
    return 0.4 + 0.6 / (1 + a.visit[a.state.energysaving.n, a.state.chan, a.state.buflevel, a.a])
end

function BaseAgent.feedback(a :: ContextQ, res :: Result, idle :: Bool = false, n_pkt :: Int = 0)
    feedback(a.s, res, idle, n_pkt)
    # if we didn't take any action that's worth learning, return immediately
    if a.a == -1
        return nothing
    end
    r :: Float64 = 0
    if idle
        r = - a.beta_idle * a.bitrate * Params.t_slot / a.s.E_slot
        if res == BufOverflow # If we were idle and overflow occurred, get some extra punishment
            r = r * Params.beta_overflow / a.beta_idle
        else
            if a.state.energysaving == MaxThroughput
                r *= 2 # double beta_idle in max throughput mode
            end
            new_buf_level = div(a.s.B_empty, a.buf_interval) + 1
            r *= 1 + 0.5 * (new_buf_level - a.buflevels / 2) / a.buflevels # increase idleness penalty with buffer level
        end
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
    max_Q_next = maximum(a.Q[a.state.energysaving.n, a.s.chan, floor(a.s.B_empty / a.buf_interval) + 1])
    Q_now = a.Q[a.state.energysaving.n, a.state.chan, a.state.buflevel, a.a]
    a.Q[a.state.energysaving.n, a.state.chan, a.state.buflevel, a.a] += alpha(a) * (r + discount * max_Q_next - Q_now)
    # Update expertness
    if r > 0
        a.expertness += r # sum of positive reinforcements for now
    end
    nothing
end

# Coordinator object for Cooperative Q
type Coordinator
    US :: Array{Float64, 3} # U*S where U*S*V' = svd(Q) for each agent
    Vt :: Array{Float64, 3} # V' where U*S*V' = svd(Q) for each agent
    function Coordinator(P :: ParamT)
        c = new()
        c.US = zeros(P.n_agent, int(Params.n_channel) * (P.buf_levels + 1), P.d_svd)
        c.Vt = zeros(P.n_agent, P.d_svd, Params.n_channel * length(Params.P_levels) + 1)
    end
end

function BaseAgent.initcoordinator(:: Type{ContextQ}, P :: ParamT)
    return Coordinator(P)
end

function expertweights(a, expertness, agents, i)
    #expertness -= min(expertness)
    # convert weights to values in [0, 1]
    distances = [norm([a.s.x, a.s.y] + rand(a.s.location_error)) for a in agents]
    distances = abs(distances - distances[i]) + 5 # +5 part is for accuracy
    expertness ./= distances .^ a.δ
    expertness .*= Params.QParams.cap_weights[[a.cap_level for a in agents]]
    weights = logistic(expertness, mean(expertness), 1, expertness[i])
    # introduce distances into weights
    #temp = weights[i]
    #weights[i] = 0
    # weights[expertness .<= expertness[i]] = 0
    # make weights one-sum
    weights = weights ./ sum(weigths)
    # normalize weights to use trustQ
    weights .*= a.trustQ / sum(weights[1:endof(weights) .!= i])
    weights[i] = 1 - a.trustQ
end

function BaseAgent.cooperate(agents :: Vector{ContextQ}, P :: ParamT, coordinator :: Coordinator, t)
    const n_agent = int(P.n_agent)
    const sharingperiod = P.sharingperiod
    # size of US + size of Vt, used for data sharing time and energy computation
    const sizeQ = P.d_svd * 64 * (EnergySaving.n * n_channel * (P.buf_levels + 1) + (n_channel * length(P_levels) + 1))
    # time slots required for an agent to send/receive Q matrix by sending/receiving US & Vt
    const timeQ = int(ceil(sizeQ ./ Params.controlcapacity ./ t_slot))
    # time required for an agent to send/receive Q matrix by sending/receiving US & Vt
    const rawtimeQ0 = sizeQ ./ Params.controlcapacity ./ t_slot
    # Shape of the Q matrix (Shape is S x A where S and A are discrete enumerated sets)
    const shapeQ = (EnergySaving.n * int(Params.n_channel) * (P.buf_levels + 1), Params.n_channel * length(Params.P_levels) + 1)
    if n_agent > 1
        US = coordinator.US
        Vt = coordinator.Vt
        # join Cooperative Q learners
        if t > Params.t_saturation && t % sharingperiod < 2 * n_agent * timeQ
            tt = t % sharingperiod
            i = fld(tt, timeQ) + 1
            # sending phase (from CR)
            if tt < n_agent * timeQ
                # receiving complete, update combined Q matrix
                # using only positive expertness ones
                if tt - (i-1) * timeQ == timeQ - 1
                    u, s, v = svd(reshape(agents[i].expertness .* agents[i].Q, shapeQ))
                    US[i, :, :] = u[:,1:P.d_svd]*diagm(s[1:P.d_svd])
                    Vt[i, :, :] = v'[1:P.d_svd, :]
                    expertness[i] = agents[i].expertness
                end
                if tt == (i - 1) * timeQ
                    # initialize control channel usage overhead
                    rawtimeQ = rawtimeQ0
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
                if tt - (i+n_agent-1) * timeQ == timeQ - 1
                    #fill!(agents[i].Q, 0)
                    # use up-to-date Q function on CR's side
                    # learning from experts (LE)
                    weights = expertweights(agents[i], expertness, agents, i)
                    agents[i].Q *= weights[i]
                    for j=1:n_agent
                        if i == j || weights[j] == 0 # || !experts[j]
                            continue
                        else
                            us = slice(US, (j, 1:size(US)[2], 1:size(US)[3]))
                            vt = slice(Vt, (j, 1:size(Vt)[2], 1:size(Vt)[3]))
                            agents[i].Q += weights[j] * reshape(us * vt, size(agents[i].Q))
                            fill!(agents[i].visit, 0)
                        end
                    end
                    agents[i].expertness = 0 # *= 1 - a.trustQ
                end
            end
        end
    end
end

end