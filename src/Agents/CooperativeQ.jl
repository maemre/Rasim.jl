
using .BaseAgent
using Params
using Traffic.Simple
using Channel.Gilbert
using Util
using Params.QParams

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

function CooperativeQ(i, P, pos)
    Q = rand(int(Params.n_channel), P.buf_levels + 1, idle_action)
    Q *= Params.P_tx * Params.t_slot # a good initial randomization
    visit = zeros(Params.n_channel, P.buf_levels + 1, idle_action)
    CooperativeQ(AgentState(i, P, pos), Q, visit, 0, (0, 0), 0, 0, Initialized, 0, div(Params.B + 1, P.buf_levels), P.beta_idle)
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
        r = - a.beta_idle * a.bitrate * Params.t_slot / a.s.E_slot
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

function BaseAgent.initcoordinator(:: Type{CooperativeQ}, P :: ParamT)
    return Coordinator(P)
end

function BaseAgent.cooperate(agents :: Vector{CooperativeQ}, P :: ParamT, coordinator :: Coordinator, t)
    const n_agent = int(P.n_agent)
    const sharingperiod = P.sharingperiod
    # size of US + size of Vt, used for data sharing time and energy computation
    # const sizeQ = P.d_svd * 64 * (n_channel * (P.buf_levels + 1) + (n_channel * length(P_levels) + 1))
    const sizeQ = 64 * n_channel * (P.buf_levels + 1) * (n_channel * length(P_levels) + 1)
    # time slots required for an agent to send/receive Q matrix by sending/receiving US & Vt
    const timeQ = int(ceil(sizeQ ./ Params.controlcapacity ./ t_slot))
    # time required for an agent to send/receive Q matrix by sending/receiving US & Vt
    const rawtimeQ0 = sizeQ ./ Params.controlcapacity ./ t_slot
    # Shape of the Q matrix
    const shapeQ = (int(Params.n_channel) * (P.buf_levels + 1), Params.n_channel * length(Params.P_levels) + 1)
    Q = zeros(n_agent, int(Params.n_channel), P.buf_levels + 1, Params.n_channel * length(Params.P_levels) + 1)
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
                    #= u, s, v = svd(reshape(agents[i].expertness .* agents[i].Q, shapeQ))
                    US[i, :, :] = u[:,1:P.d_svd]*diagm(s[1:P.d_svd])
                    Vt[i, :, :] = v'[1:P.d_svd, :] =#
                    Q[i,:,:,:] = agents[i].expertness .* agents[i].Q
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
                    weight = 1 - P.trustQ
                    agents[i].Q *= weight #* reshape(Q[j,:,:,:], size(agents[i].Q))
                    # learning from experts (LE)
                    # choose some experts randomly
                    experts = zeros(Bool, n_agent)
                    for expert in shuffle!([[x for x=1:i-1],[x for x=i+1:n_agent]])[1:fld(n_agent, 2)]
                        experts[expert] = true
                    end
                    for j=1:n_agent
                        if i == j
                            continue
                        elseif !experts[j]
                            continue
                        else
                            if expertness[j] > expertness[i]
                                weight = P.trustQ * (expertness[j] - expertness[i])
                                # normalize
                                weight ./= sum((expertness - expertness[i]) .* (expertness .> expertness[i]))
                                #= us = slice(US, (j, 1:size(US)[2], 1:size(US)[3]))
                                vt = slice(Vt, (j, 1:size(Vt)[2], 1:size(Vt)[3]))
                                agents[i].Q += weight * reshape(us * vt, size(agents[i].Q)) =#
                                agents[i].Q += weight * reshape(Q[j,:,:,:], size(agents[i].Q))
                            end
                        end
                    end
                    agents[i].expertness = 0 # *= 1 - P.trustQ
                end
            end
        end
    end
end