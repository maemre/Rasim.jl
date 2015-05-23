module BaseAgent

using Movement
using Params
using Channel.Gilbert
using Traffic.Simple
using Distributions
using DataStructures: Queue, Deque, enqueue!, dequeue!, front, back

export AgentState, Environment, Agent, Result, Success, Collision, BufOverflow, LostInChannel,
       Action, Transmit, Sense, Idle, move, fillbuffer, idle, act_then_idle, sense, feedback,
       switch!, transmit!, Status, Initialized, Switched, Sensed, Transmitted, initial_action,
       act, switch, Switch, EndTransmission, initcoordinator, cooperate, detect_traffic

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

immutable Status
    n :: Int
    Status(n) = new(n)
end

const Initialized = Status(0)
const Switched = Status(1)
const Sensed = Status(2)
const Transmitted = Status(3)

# Energy saving modes
immutable EnergySavingMode
    n :: Int
end

MaxThroughput = EnergySaving = EnergySavingMode(1)

export EnergySavingMode, EnergySaving, MaxThroughput

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
    pd :: Float64 # Probability of detection
    pf :: Float64 # Probability of false alarm
    cap_level :: Int # capability level
    location_error :: ZeroMeanIsoNormal # Location accuracy distribution
    B_empty :: Int16 # empty buffer slots
    B_max :: Int16
    buf_overflow :: Bool
    id :: Int8
    chan :: Int8 # current channel
    energysaving :: EnergySavingMode
    pktqueue :: Queue{Deque{Int}} # Creation time-slot of packets
    function AgentState(i :: Int8, P :: ParamT, pos :: Point{Float64})
        a = new()
        a.pos = pos
        a.t_remaining = Params.t_slot
        a.speed = i < P.n_stationary_agent ? 30. / 3.6 : 0
        a.n_pkt_slot = 0
        a.E_slot = 0
        a.E_sw = 0
        a.E_tx = 0
        a.E_sense = 0
        a.E_idle = 0
        a.walk = randomwalk(a.speed, int(10 / Params.t_slot))
        a.cap_level = P.caplevels[i]
        # distribute pd-pf pairs using round robin
        a.pd = Params.pd[a.cap_level]
        a.pf = Params.pf[a.cap_level]
        a.location_error = MvNormal(2, Params.eps_accuracy[a.cap_level])
        a.B_max = Params.B
        a.B_empty = Params.B
        a.buf_overflow = false
        a.id = i
        a.chan = rand(1:Params.n_channel)
        a.energysaving = EnergySaving # i % 2 == 0 ? MaxThroughput : EnergySaving
        a.pktqueue = Queue(Int)
        a
    end
end

abstract Action

type Transmit <: Action
    power :: Float64
    bitrate :: Float64
    chan :: Int8
    n_pkt :: Int16
    i :: Int8
end

type EndTransmission <: Action
    power :: Float64
    bitrate :: Float64
    chan :: Int8
    n_pkt :: Int16
    i :: Int8
    EndTransmission(t::Transmit) = new(t.power,t.bitrate,t.chan,t.n_pkt,t.i)
end

Transmit(t::EndTransmission) = Transmit(t.power,t.bitrate,t.chan,t.n_pkt-1,t.i)

type Idle <: Action
    i :: Int8
end

type Sense <: Action
    chan :: Int8
    i :: Int8
end

type Switch <: Action
    chan :: Int8
    i :: Int8
end

function move!(s :: AgentState, t :: Int64)
    s.pos += s.walk(t)
end

function fillbuffer(a :: Agent, P :: ParamT, t :: Int64)
    s :: AgentState = a.s
    pkgs = rand(Params.pkt_min:P.pkt_max)
    if pkgs > s.B_empty
        s.buf_overflow = true
        feedback(a, BufOverflow)
        pkgs = s.B_empty
        s.B_empty = 0
    else
        s.buf_overflow = false
        s.B_empty -= pkgs
    end
    for i = 1:pkgs
        enqueue!(s.pktqueue, t)
    end
    nothing
end

function idle(a :: Agent, t :: Float64 = -1.)
    s :: AgentState = a.s
    if t < 0 || t > s.t_remaining
        t = s.t_remaining
    end
    s.E_idle += Params.P_idle * t
    s.E_slot += Params.P_idle * t
    s.t_remaining -= t
    Idle(s.id)
end

function initial_action(a :: Agent, env :: Environment, t :: Int64, P)
    fillbuffer(a, P, t)
    move!(a.s, t)
    s :: AgentState = a.s
    s.n_pkt_slot = 0
    s.t_remaining = Params.t_slot
    # Add backoff
    idle(a, Params.t_backoff * rand())
    s.E_slot = 0
    s.E_sw = 0
    s.E_tx = 0
    s.E_sense = 0
    s.E_idle = 0
    a.status = Initialized
    act(a, env, t)
end

function sense(a :: Agent, env :: Environment, detect_traffic :: Function)
    s :: AgentState = a.s
    if s.t_remaining < Params.t_sense
        error("No time remained for sensing")
    end
    s.t_remaining -= Params.t_sense
    E_sense = Params.P_sense * Params.t_sense
    s.E_sense += E_sense
    s.E_slot += E_sense
    a.status = Sensed
    Sense(s.chan, s.id)
end

function detect_traffic(s :: AgentState, t :: SimpleTraffic, t_remaining :: Float64)
    # if channel is occupied for less than half of sensing time
    # we can't sense the traffic, so use pf (actually this logic should be revised)
    sensing = t.occupancy < (Params.t_slot - t_remaining - 0.5 * Params.t_sense)
    rand() < (sensing ? pd : pf)
end

function feedback(s :: AgentState, res :: Result, idle :: Bool = false, n_pkt :: Int = 0)
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

function feedback(a :: Agent, res :: Result, idle :: Bool = false, n_pkt :: Int = 0)
    feedback(a.s, res, idle, n_pkt)
end

function switch(a :: Agent, c :: Int8)
    Switch(c, a.s.id)
end

function switch!(a :: Agent, c :: Int8)
    s :: AgentState = a.s
    t_sw = Params.t_sw * abs(c - s.chan)
    if s.t_remaining < t_sw
        error(sprintf("No time remained for switching from chan #%d to chan #%d", s.chan, c))
    end

    E_sw = t_sw * Params.P_sw
    s.E_sw += E_sw
    s.E_slot += E_sw
    s.t_remaining -= t_sw
    s.chan = c
    a.status = Switched
    nothing
end

function transmit!(a :: Agent, P_tx, env, n_pkt)
    s :: AgentState = a.s
    n_bits = n_pkt * Params.pkt_size
    bitrate = capacity(env.channels[s.chan], P_tx, s.pos)
    if s.t_remaining < n_bits / bitrate
        println(s.t_remaining)
        error(@sprintf("Not enough time to transmit %d bits with bitrate %f", n_bits, bitrate))
    end
    s.n_pkt_slot = n_pkt
    s.t_remaining -= n_bits / bitrate
    E_tx = P_tx * n_bits / bitrate
    s.E_tx += E_tx
    s.E_slot += E_tx
    a.status = Transmitted
    Transmit(P_tx, bitrate, s.chan, n_pkt, s.id)
end

function act(a :: Agent)
    error("Not implemented")
end

initcoordinator{AgentT <: Agent}(:: Type{AgentT}, P :: ParamT) = nothing

cooperate{AgentT <: Agent}(agents :: Vector{AgentT}, P :: ParamT, coordinator, t) = nothing

end