module Params

using Util

export t_slot, prefix, batch_run, verbose, n_runs, t_total, n_agent, n_stationary_agent, n_channel,
       n_good_channel, r_init, B, pkt_size, b_size, pkt_min, pkt_max, base_freq, chan_bw,
       chan_trans_prob, noise

# Simulation parameters:
const batch_run = false
const verbose = true && !batch_run
const debug = false
# number of runs
const n_runs = 10
# time slot
const t_slot = 10e-3 # s
# total simulation time (as time slots)
const t_total = int(floor(60 / t_slot)) # convert seconds to time slots
# total number of agents
const n_agent = int8(1)
# number of stationary agents
const n_stationary_agent = div(n_agent, 2)
# number of channels
const n_channel = int8(5)
# number of good channels
const n_good_channel = int8(2)
# radius of initial map
const r_init = 5000

# Buffer parameters

# number of buffer slots
const B = int16(512) # packets
# Size of a buffer slot (also packet size)
const pkt_size = 1024 # bits
# buffer size in bits
const b_size = B * pkt_size
# package rate for buffer traffic
# defined as a discrete uniform distribution with parameters:
const pkt_min = 0 # pkg / slot, inclusive
const pkt_max = 6 # pkg / slot, inclusive
const buf_levels = 4
const beta_idle = 20.

# durations
const t_sense = 0.1 * t_slot
const t_sw = 0.05 * t_slot
const t_backoff = Params.t_sense * 3

# powers
const P_tx = 200e-3 # W
const P_levels = [0.5 0.75 1 2] * P_tx
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
const chan_trans_prob = [0.95 0.05; 0.4 0.6]'
# channel noises for each channel type (type 1, type 2 etc)
const P_sig = todBm(P_tx/chan_bw) # signal power density in dBm
const noise = [-98 -95; -174 -100]

#traffic parameters
const traffic_trans_prob =  [0.9 0.1; 0.4 0.6]'
const traffic_probs = [0.3; 0.7]

# Q learning parameters
# saturation time of initial values
const t_saturation = 1000
# period of sharing experiences
const sharingperiod = 500
# size of Q matrix, used for data sharing computation
const sizeQ = 64 * n_channel * (buf_levels + 1) * (n_channel * length(P_levels) + 1)
# capacity of control channel, assuming SNR of channel is 7 dB
const controlcapacity = 1e6 * log2(1 + 10 .^ 0.7)
# time slots required for an agent to send/receive Q matrix
const timeQ = int(ceil(sizeQ ./ controlcapacity ./ t_slot))
# time required for an agent to send/receive Q matrix
const rawtimeQ = sizeQ ./ controlcapacity ./ t_slot
# trust to others' experiences
const trustQ = 0.1

const prefix = @sprintf("%d-%d-%d-%d-%d-%d-%d-%f", n_runs, t_total, n_agent, n_channel, n_good_channel, buf_levels, pkt_size, beta_idle)

end
