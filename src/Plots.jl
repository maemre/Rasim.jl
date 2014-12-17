module Plots

using Winston
using Params

export initplots, plot_ee, displayplots

const colors = ["blue"; "green"; "red"]

p_ee = None

function initplots()
    global p_ee = FramedPlot(
            title="EE vs Time (Cumulative)",
            xlabel="Time (time slots)",
            ylabel="EE (\\Sigma b/\\Sigma E) (b/J)")
end

function plot_ee(energies, bits, agent, i)
    add(p_ee, Curve(1:t_total, vec(cumsum(sum(bits, 1), 2) ./ cumsum(sum(energies, 1), 2)), color=colors[i]))
    nothing
end

function displayplots()
    map(display, [p_ee])
end

end # module