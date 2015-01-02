module Util

using HDF5, JLD

export todBm, toWatt, @save_compressed

function todBm(P_watt)
    10 .* log10(P_watt) + 30
end

function toWatt(P_dBm)
    10 .^ ((P_dBm - 30) ./ 10)
end

macro save_compressed(filename, vars...)
    if isempty(vars)
        # Save all variables in the current module
        pushexprs = Array(Expr, 0)
        m = current_module()
        for vname in names(m)
            s = string(vname)
            if !ismatch(r"^_+[0-9]*$", s) # skip IJulia history vars
                v = eval(m, vname)
                if !isa(v, Module)
                    push!(pushexprs, :(push!(d, $s, $(esc(vname)))))
                end
            end
        end
    else
        pushexprs = Array(Expr, length(vars))
        for i = 1:length(vars)
            pushexprs[i] = :(push!(d, $(string(vars[i])), $(esc(vars[i]))))
        end
    end

    quote
        d = Dict{String}{Any}()
        $(Expr(:block, pushexprs...))
        save($filename, d, compress=true)
    end
end

end