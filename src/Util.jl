module Util

export todBm, toWatt

function todBm(P_watt)
    10 .* log10(P_watt) + 30
end

function toWatt(P_dBm)
    10 .^ ((P_dBm - 30) ./ 10)
end

end