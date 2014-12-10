module BaseAgent

using Movement
using Params
using Channel.Gilbert
using Traffic.Simple

export AgentState, Environment, Agent, Result, Success, Collision, BufOverflow, LostInChannel,
       Action, Transmit, Sense, Idle, move, fillbuffer, idle, act_then_idle, sense, feedback,
       switch!, transmit!

type Environment
    channels :: Vector{GilbertChannel}
    traffics :: Vector{SimpleTraffic}
end

abstract Agent

# Define an enum as in enum macro in examples
immutable Result
    n :: Int
    Result(n::Int) = new(n)
end

const Success = Result(0)
const Collision = Result(1)
const BufOverflow = Result(2)
const LostInChannel = Result(3)

# I align structures for smaller memory footprint (size matters!)
type AgentState
    pos :: Point{Float64} # position
    t_remaining :: Float64
    speed :: Float64
    # Slot statistics
    n_pkt_slot :: Int64
    E_idle :: Float64
    E_tx :: Float64
    E_sw :: Float64
    E_sense :: Float64
    E_slot :: Float64
    walk :: Function
    B_empty :: Int16 # empty buffer slots
    B_max :: Int16
    buf_overflow :: Bool
    id :: Int8
    chan :: Int8 # current channel
    function AgentState(i :: Int8)
        a = new()
        r = sqrt(rand()) * Params.r_init
        theta = rand()*2*pi
        a.pos = Point(r * cos(theta), r * sin(theta))
        a.t_remaining = Params.t_slot
        a.speed = i < Params.n_stationary_agent ? 30. / 3.6 : 0
        a.n_pkt_slot = 0
        a.E_slot = 0
        a.E_sw = 0
        a.E_tx = 0
        a.E_sense = 0
        a.E_idle = 0
        a.walk = randomwalk(a.speed, int(10 / Params.t_slot))
        a.B_max = Params.B
        a.B_empty = Params.B
        a.buf_overflow = false
        a.id = i
        a.chan = rand(1:Params.n_channel)
        a
    end
end

abstract Action

type Transmit <: Action
    power :: Float64
    bitrate :: Float64
    chan :: Int8
    n_pkt :: Int16
end

type Idle <: Action
end

type Sense <: Action
    backoff :: Float64
    chan :: Int8
end

function move!(s :: AgentState, t :: Int64)
    s.pos += s.walk(t)
end

function fillbuffer(a :: Agent)
    s :: AgentState = a.s
    pkgs = rand(Params.pkt_min:(Params.pkt_max + 1))
    if pkgs > s.B_empty
        s.buf_overflow = true
        feedback(a, BufOverflow)
        s.B_empty = 0
    else
        s.buf_overflow = false
        s.B_empty -= pkgs
    end
    nothing
end

function idle(a :: Agent, t :: Float64 = -1.)
    s :: AgentState = a.s
    if t < 0 || t > s.t_remaining
        t = s.t_remaining
    end
    s.E_idle += Params.P_idle * t
    s.E_slot += s.E_idle
    s.t_remaining -= t
    Idle()
end

function act_then_idle(a :: Agent, env :: Environment, t :: Int64)
    fillbuffer(a)
    move!(a.s, t)
    s :: AgentState = a.s
    s.n_pkt_slot = 0
    s.t_remaining = Params.t_slot
    s.E_slot = 0
    s.E_sw = 0
    s.E_tx = 0
    s.E_sense = 0
    s.E_idle = 0
    action = act(a, env, t)
    idle(a)
    action
end

function sense(a :: Agent, env :: Environment, detect_traffic :: Function)
    s :: AgentState = a.s
    if s.t_remaining < Params.t_sense
        error("No time remained for sensing")
    end
    s.t_remaining -= Params.t_sense
    s.E_sense = Params.P_sense * Params.t_sense
    s.E_slot += s.E_sense
    detect_traffic(env.traffics[s.chan])
end

function feedback(s :: AgentState, res :: Result, idle :: Bool = false, n_pkt :: Int16 = int16(0))
    if idle || res == BufOverflow
        return 
    elseif res == Success
        s.B_empty += n_pkt
    end
    if s.B_empty > s.B_max
        error("Error in simulation, buffer underflow!")
        s.B_empty = s.B_max
    end
    nothing
end

function feedback(a :: Agent, res :: Result, idle :: Bool = false, n_pkt :: Int16 = int16(0))
    feedback(a.s, res, idle, n_pkt)
end

function switch!(s :: AgentState, c :: Int8)
    t_sw = Params.t_sw * abs(c - s.chan)
    if s.t_remaining < t_sw
        error(sprintf("No time remained for switching from chan #%d to chan #%d", s.chan, c))
    end

    s.E_sw = t_sw * Params.P_sw
    s.E_slot += s.E_sw
    s.t_remaining -= t_sw
    s.chan = c
    nothing
end

function transmit!(s :: AgentState, P_tx, env, n_pkt)
    n_bits = n_pkt * Params.pkt_size
    bitrate = capacity(env.channels[s.chan], P_tx, s.pos)
    if s.t_remaining < n_bits / bitrate
        println(s.t_remaining)
        error(@sprintf("Not enough time to transmit %d bits with bitrate %f", n_bits, bitrate))
    end
    s.n_pkt_slot = n_pkt
    s.t_remaining -= n_bits / bitrate
    s.E_tx = P_tx * n_bits / bitrate
    s.E_slot += s.E_tx

    Transmit(P_tx, bitrate, s.chan, n_pkt)
end

function act(a :: Agent)
    error("Not implemented")
end

end