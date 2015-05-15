module Util

using DataStructures: DefaultDict

export todBm, toWatt, logsumexp, logistic

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

# Helper function for dumping DefaultDicts
function Base.convert{K, V, D}(T ::Type{Dict{K, V}}, dd :: DefaultDict{K, V, D})
    d = T()
    for (k, v) in dd
        d[k] = v
    end
    d
end

#=
the logistic function where
  L is the maximum value,
  k is steepness of the curve,
  x0 is the midpoint
=#
logistic(x, k=1, L=1, x0=0) = L ./ (1 + exp(-k * (x - x0)))

# unit step function, returning int
ustepi(x) = int(x .> 0)

# unit step function, returning float
ustep(x) = float(x .> 0)

end