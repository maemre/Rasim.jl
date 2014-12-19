module Plots

using Winston
using Params

export initplots, plot_ee, displayplots

const colors = ["blue"; "green"; "red"; "cyan"; "magenta"; "yellow"; "black"]

type PlotFig
    l :: Array{Any, 1}
    p :: FramedPlot
    PlotFig() = new({})
end

p_ee = PlotFig()
p_ee_conv = PlotFig()

function initplots()
    p_ee.p = FramedPlot(
            title="EE vs Time (Cumulative)",
            xlabel="Time (time slots)",
            ylabel="EE (\\Sigma b/\\Sigma E) (b/J)")
    p_ee_conv.p = FramedPlot(
            title="EE vs Time (1201 Pt Average)",
            xlabel="Time (time slots)",
            ylabel="EE (b/E) (b/J)")
end

function plot_ee(energies, bits, agent, i)
    ee = Curve(1:t_total, vec(cumsum(sum(bits, 1), 2) ./ cumsum(sum(energies, 1), 2)), color=colors[i])
    setattr(ee, "label", agent)
    add(p_ee.p, ee)
    push!(p_ee.l, ee)
    ee_conv = Curve(1:t_total-2399, conv(vec(sum(bits, 1) ./ sum(energies, 1)), fill(1./1201, 1201))[1201:end-1200], color=colors[i])
    setattr(ee_conv, "label", agent)
    add(p_ee_conv.p, ee_conv)
    push!(p_ee_conv.l, ee_conv)
    nothing
end

function displayplots()
    for p in [p_ee, p_ee_conv]
        f=figure()
        add(p.p, Legend(.8, .8, p.l))
        display(p.p)
        figure(f)
        savefig(string(getattr(p.p, "title"), ".png"))
        savefig(string(getattr(p.p, "title"), ".svg"))
    end
end

end # module