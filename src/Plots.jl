module Plots

using Winston
using Params

export initplots, plot_ee, displayplots, plot_buf

const colors = ["cyan"; "green"; "red"; "blue"; "magenta"; "yellow"; "black"]

type PlotFig
    l :: Array{Any, 1}
    p :: FramedPlot
    PlotFig() = new({})
end

p_ee = PlotFig()
p_ee_conv = PlotFig()
p_th = PlotFig()
p_buf = PlotFig()

function initplots()
    p_ee.p = FramedPlot(
            title="EE vs Time (Cumulative)",
            xlabel="Time (time slots)",
            ylabel="EE (\\Sigma b/\\Sigma E) (b/J)")
    p_ee_conv.p = FramedPlot(
            title="EE vs Time (501 Pt Average)",
            xlabel="Time (time slots)",
            ylabel="EE (b/E) (b/J)")
    p_th.p = FramedPlot(
            title="Throughput vs Time (501 Pt Average)",
            xlabel="Time (time slots)",
            ylabel="Throughput (b)")
    p_buf.p = FramedPlot(
            title="Buffer Occupancy (501 Pt Average)",
            xlabel="Time (time slots)",
            ylabel="Buffer Occupancy (b)")
end

function plot_ee(energies, bits, agent, i)
    # start from 100 in total EE plot to see the differences more easily
    ee = Curve(100:t_total, vec(cumsum(sum(bits, 1), 2) ./ cumsum(sum(energies, 1), 2))[100:end], color=colors[i])
    setattr(ee, "label", agent)
    add(p_ee.p, ee)
    push!(p_ee.l, ee)
    ee_conv = Curve(500:t_total, conv(vec(sum(bits, 1) ./ sum(energies, 1)), fill(1./501, 501))[500:end-500], color=colors[i])
    setattr(ee_conv, "label", agent)
    add(p_ee_conv.p, ee_conv)
    push!(p_ee_conv.l, ee_conv)
    th = Curve(500:t_total, conv(vec(sum(bits, 1)), fill(1./501, 501))[500:end-500], color=colors[i])
    setattr(th, "label", agent)
    add(p_th.p, th)
    push!(p_th.l, th)
    nothing
end

function plot_buf(buf_levels, agent, i)
    # start from 100 in total EE plot to see the differences more easily
    buf = Curve(500:t_total, conv(vec(sum(buf_levels, 1)), fill(1./501, 501))[500:end-500], color=colors[i])
    setattr(buf, "label", agent)
    add(p_buf.p, buf)
    push!(p_buf.l, buf)
    nothing
end

function displayplots()
    for p in [p_ee, p_ee_conv, p_th, p_buf]
        f=figure()
        add(p.p, Legend(.7, .7, p.l))
        display(p.p)
        figure(f)
        savefig(string(getattr(p.p, "title"), ".png"))
        savefig(string(getattr(p.p, "title"), ".svg"))
    end
end

end # module