module Simple

import Params
using Distributions

export SimpleTraffic, detect_traffic

type SimpleTraffic
    traffic_probs :: Array{Float64, 1} # traffic probabilities of states
    A :: Array{Float64, 2} # transition probabilities
    state :: Int # current state
    traffic :: Bool # whether traffic exists
    SimpleTraffic(state = 1) = new(Params.traffic_probs, Params.traffic_trans_prob, state, false)
end

function iterate(t :: SimpleTraffic)
    t.state = rand(Categorical(t.A[:, t.state]))
    t.traffic = rand() <= t.traffic_probs[t.state]
end

# detection and false alarm probabilities
const pd = 0.9
const pf = 0.1

function detect_traffic(t :: SimpleTraffic)
    rand() < (t.traffic ? pd : pf)
end

end