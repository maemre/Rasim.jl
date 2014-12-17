module Plots

using Winston
using Params

export initplots, plot_ee, displayplots

const colors = ["blue"; "green"; "red"]

p_ee = None
p_ee_conv = None

function initplots()
    global p_ee = FramedPlot(
            title="EE vs Time (Cumulative)",
            xlabel="Time (time slots)",
            ylabel="EE (\\Sigma b/\\Sigma E) (b/J)")
    global p_ee_conv = FramedPlot(
            title="EE vs Time (1201 Pt Average)",
            xlabel="Time (time slots)",
            ylabel="EE (b/E) (b/J)")
end

function plot_ee(energies, bits, agent, i)
    add(p_ee, Curve(1:t_total, vec(cumsum(sum(bits, 1), 2) ./ cumsum(sum(energies, 1), 2)), color=colors[i]))
    add(p_ee_conv, Curve(1:t_total-2399, conv(vec(sum(bits, 1) ./ sum(energies, 1)), fill(1./1201, 1201))[1201:end-1200], color=colors[i]))
    nothing
end

function displayplots()
    for p in [p_ee, p_ee_conv]
        figure()
        display(p)
    end
end

end # module