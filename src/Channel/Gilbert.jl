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
    nothing
end

function iterate!(c :: GilbertChannel)
    c.state = rand(Categorical(c.A[:, c.state]))
    c.n0 = c.noises[c.state]
    c.noise = toWatt(c.n0) * c.bandwidth
    c.interference = 0
    nothing
end

function berawgn(c :: GilbertChannel, E_b)
    0.5 * erfc(sqrt(E_b / ((c.noise + c.interference) / c.bandwidth)))
end

function capacity(c :: GilbertChannel, power, pos)
    # Do not use Shannon capacity, since we're using QPSK with a fixed bandwidth
    # and it's suboptimal
    # d = sqrt(pos.x ^ 2 + pos.y ^ 2)
    # power *= (3e8 / (4 * pi * d * c.freq)) .^ 2
    # c.bandwidth * log2(1 + power / c.noise)
    # Assuming we're using a fixed bitrate
    Params.bitrate
end

function success_prob(c :: GilbertChannel, E_b)
    n = Params.pkt_size
    k = Params.pkt_redundancy
    p = berawgn(c, E_b)
    # use binomial sum to calculate successful transmission probability
    log_prob = logsumexp((k+1) .* [log1p(-p), log(p)]) - log1p(-2p) + (n-k) * log1p(-p)
    exp(log_prob)
end

function transmission_successes(c :: GilbertChannel, power, bitrate, x, y, indoor=false)
    d = sqrt(x ^ 2 + y ^ 2)
    # use Hata model for outdoor loss
    loss = 32.4 + 20 * (log10(c.freq / 1e9) + log10(d))
    if indoor
        # use COST-231 path loss eqn for indoor to get received power
        l_e = 7
        l_ge = 6 # approx. for all incidence angles
        Γ1 = Params.Indoor.walls * 7
        Γ2 = 0.6 * Params.Indoor.d_indoor * 0.55 # integrate for all incidence angles
        l_indoor = l_e + l_ge + max(Γ1, Γ2)
        loss += l_indoor
    end
    P_r = 10 ^ (log10(power) - (loss / 10))
    # compute energy per bit
    E_b = P_r / bitrate
    # compute per-packet success rate
    success_rate = success_prob(c, E_b)
    #rand(Binomial(n_pkt, success_rate))
    # we're generating single packets now
    rand(Bernoulli(success_rate))
end

end