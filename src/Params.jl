module Params

using Util

export t_slot, prefix, batch_run, verbose, n_runs, t_total, n_agent, n_stationary_agent, n_channel,
       r_init, B, pkt_size, b_size, pkt_min, pkt_max, base_freq, chan_bw, chan_trans_prob, noise, P_levels

# Simulation parameters:
const batch_run = false
const verbose = true && !batch_run
const debug = false
# number of runs
const n_runs = 10
# time slot
const t_slot = 10e-3 # s
# total simulation time (as time slots)
const t_total = int(floor(100 / t_slot)) # convert seconds to time slots
# number of channels
const n_channel = int8(5)
# radius of initial map
const r_init = 1000

# Buffer parameters

# number of buffer slots
const B = int16(1024) # packets
# Size of a buffer slot (also packet size)
const pkt_size = 1024 # bits
# buffer size in bits
const b_size = B * pkt_size
# package rate for buffer traffic
# defined as a discrete uniform distribution with parameters:
const pkt_min = 0 # pkg / slot, inclusive
const pkt_redundancy = 0.1 # redundancy (error resilience ratio) of packets

# durations
const t_sense = 0.1 * t_slot
const t_sw = 0.05 * t_slot
const t_backoff = Params.t_sense * 3

# powers
const P_tx = 200e-3 # W
const P_levels = [0.5 1 2 4] * P_tx
const P_sense = 0.5*P_tx
const P_sw = 0.5*P_tx
const P_idle = 0.2*P_tx
const P_rec = 40 # W

# channel parameters
const base_freq = 9e8 # 900 MHz
const chan_bw = 1e6 # 1 MHz
# allowed bitrate
const bitrate = 3.75e6 # 1 Mbps
# state transition probabilities, first state is good state
const chan_trans_prob = [0.8 0.2; 0.8 0.2]'
# channel noises for each channel type (type 1, type 2 etc)
const P_sig = todBm(P_tx/chan_bw) # signal power density in dBm
const noise = todBm(P_tx * (3e8 / (4 * pi * r_init * base_freq)) .^ 2 / bitrate) + [-5 0; -6 -4.5]

#traffic parameters
const traffic_trans_prob =  [0.7 0.3; 0.9 0.1]'
const traffic_probs = [0.3; 0.7]

# Q learning parameters
module QParams

export beta_overflow, beta_md, beta_loss, epsilon, discount

const beta_overflow = 100
const beta_md = 1 # misdetection punishment coefficient
const beta_loss = 2 # punishment for data loss in channel
const epsilon = 0.05 # exploration probability
const discount = 0.4 # discount factor, gamma
end
# saturation time of initial values
const t_saturation = 1000
# capacity of control channel, assuming SNR of channel is 7 dB
const controlcapacity = 1e6 * log2(1 + 10 .^ 0.7)
# trust to others' experiences
const trustQ = 0.1
# # of dimensions for SVD approximation
const d_svd = 7

# detection and false alarm probabilities for diferent agent types
const pd = [0.90, 0.96]
const pf = [0.10, 0.04]
# Location accuracy for different agent types
const eps_accuracy = [50 1] .^ 2

export ParamT, genparams

type ParamT
    beta_idle :: Float64
    sharingperiod :: Int
    buf_levels :: Int
    pkt_max :: Int
    n_stationary_agent :: Int
    iteration :: Int
    prefix :: ASCIIString
    n_agent :: Int8
    n_good_channel :: Int8
    caplevels :: Vector{Int}
end

function gencaplevels(n_agent, k, n)
    @assert 0 <= k <= n
    caplevels = ones(Int, n_agent)
    indexes = [1:n_agent] .% n
    indexes[indexes .== 0] = n
    caplevels[indexes .<= k] += 1
    caplevels
end

function genparams()
    params = Array(ParamT,0)
    i = 1
    n_good_channel = int8(3)
    buf_levels = 10
    beta_idle = 2
    sharingperiod = 1000
    for density in [(4, 8), (7, 10)]
        n_agent = int8(density[1])
        pkt_max = int8(density[2])
        for goodratio in [(2, 7), (1, 2), (3, 4)]
            caplevels = gencaplevels(n_agent, goodratio[1], goodratio[2])
            prefix = @sprintf("%d-%d-%d-%d-%f-%d-%d", n_runs, t_total, n_agent, pkt_max, beta_idle, goodratio[1], goodratio[2])
            push!(params, ParamT(beta_idle, sharingperiod, buf_levels, pkt_max, div(n_agent, 2), i, prefix, n_agent, n_good_channel, caplevels))
            i += 1
        end
    end
    params
end

end
