module Util

export todBm, toWatt, logsumexp

function todBm(P_watt)
    10 .* log10(P_watt) + 30
end

function toWatt(P_dBm)
    10 .^ ((P_dBm - 30) ./ 10)
end

function logsumexp{T}(v :: Vector{T})
    vmax = maximum(v)
    vmax + log(sum(exp(v - vmax)))
end

end