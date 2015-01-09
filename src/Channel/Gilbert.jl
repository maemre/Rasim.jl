module Gilbert

using Distributions
import Params
using Util

export GilbertChannel, iterate!, interfere!, berawgn, capacity, transmission_successes

type GilbertChannel
    # channel frequency, in Hz
    freq :: Float64
    # channel bandwidth, used here for increasing data locality hopefully
    bandwidth :: Float64
    noise :: Float64 # noise, in watt
    n0 :: Float64 # noise density, in dBm
    state :: Int # current state
    interference :: Float64 # current interference in the channel
    # noises, in dBmW
    noises :: Array{Float64, 1}
    A :: Array{Float64, 2} # transition probabilities

    function GilbertChannel(freq, noises, A)
        c = new()
        c.freq = freq
        c.noises = vec(noises)
        c.state = int(rand() <= 0.5) + 1
        c.bandwidth = Params.chan_bw
        c.n0 = c.noises[c.state]
        c.noise = toWatt(c.n0) * c.bandwidth
        c.interference = 0
        c.A = A
        c
    end

end

const states = eye(size(Params.noise, 1))

function interfere!(c :: GilbertChannel, power, pos)
    d = sqrt(pos.x ^ 2 + pos.y ^ 2)
    power *= (3e8 / (4 * pi * d * c.freq)) .^ 2
    c.interference += power
end

function iterate!(c :: GilbertChannel)
    c.state = rand(Categorical(c.A[:, c.state]))
    c.n0 = c.noises[c.state]
    c.noise = toWatt(c.n0) * c.bandwidth
    c.interference = 0
end

function berawgn(c :: GilbertChannel, E_b)
    0.5 * erfc(sqrt(E_b / ((c.noise + c.interference) / c.bandwidth)))
end

function capacity(c :: GilbertChannel, power, pos)
    d = sqrt(pos.x ^ 2 + pos.y ^ 2)
    power *= (3e8 / (4 * pi * d * c.freq)) .^ 2
    # Do not use Shannon capacity, since we're using QPSK
    # and it's suboptimal
    # c.bandwidth * log2(1 + power / c.noise)
    # Assuming we're using a fixed bitrate
    Params.bitrate
end

function transmission_successes(c :: GilbertChannel, power, bitrate, x, y)
    # apply Friis transmission eqn to get received power
    d = sqrt(x ^ 2 + y ^ 2)
    P_r = power * (3e8 / (4 * pi * d * c.freq)) .^ 2
    # compute energy per bit
    E_b = P_r / bitrate
    # compute per-packet success rate
    success_rate = exp(log1p(-berawgn(c, E_b)) * Params.pkt_size)
    #rand(Binomial(n_pkt, success_rate))
    # we're generating single packets now
    rand(Bernoulli(success_rate))
end

end