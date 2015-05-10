print("Loading modules...")

print("Params...")
using Params
print("DataFrames...")
using DataFrames
print("JLD...")
using HDF5, JLD
print("Gadfly...")
using Gadfly

println("DONE")

function getdata()
    df = DataFrame()
    df[:goodratio] = Float64[]
    df[:pkt_max] = Int[]
    df[:n_agent] = Int[]
    df[:agent_type] = String[]
    df[:throughput] = Float64[]
    df[:energy] = Float64[]
    df[:generated_packets] = Float64[]
    df[:tried_packets] = Float64[]
    df[:sent_packets] = Float64[]
    df[:buf_levels] = Float64[]
    df[:buf_overflow] = Float64[]
    df[:en] = Array(Array{Float64,1}, 0)
    df[:bits] = Array(Array{Float64,1}, 0)
    df[:prefix] = String[]
    df[:t] = Vector{Float64}[]
    agent_types = ["CooperativeQ", "OptHighestSNR", "RandomChannel", "ContextQ"]
    for P = genparams()
        dir = joinpath("data/", P.prefix)
        if ! isdir(dir)
            continue
        end
        println("Processing ", P.prefix)
        s=DataFrame(agent_type=ASCIIString[], buf=Float64[], en=Float64[], t=Int64[], bits=Float64[], ee=Float64[], cumee=Float64[], cumth=Float64[])
        for at in agent_types
            file = jldopen(joinpath(dir, "$at.jld"), "r")
            energy = read(file, "avg_energies")
            bits = read(file, "avg_bits")
            buf_overflow = read(file, "avg_buf_overflows")
            buf_levels = read(file, "avg_buf_levels")
            generated_packets = mean(read(file, "generated_packets"))
            tried_packets = mean(read(file, "tried_packets"))
            sent_packets = mean(read(file, "sent_packets"))
            ee = mean(bits)/mean(energy)
            println("$at\t$ee\t$buf_levels\t$buf_overflow")
            #=d = {P.beta_idle P.sharingperiod P.pkt_max P.n_agent P.n_good_channel at mean(bits) mean(energy) generated_packets tried_packets sent_packets buf_levels buf_overflow vec(mean(energy, [1])) vec(mean(bits, [1])) P.prefix [1:30000]}
            push!(df, d)=#
            b=vec(mean(bits, [1]))
            en=vec(mean(energy, [1]))
            ee_ = b ./ en
            dd = DataFrame(agent_type=fill(at, t_total), buf=vec(mean(read(file, "buf_matrix"), [1])), en=e, t=[1:t_total], bits=b, ee=ee_, cumee=cumsum(b) ./ cumsum(e), cumth=cumsum(b))
            append!(s, dd)
            close(file)
        end
        prefix = P.prefix
        s[:t] .*= 10e-3
        theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=1mm, default_point_size=0.8mm)
        yticks = {:th => Guide.yticks(ticks=[1000:1000:7000]), :ee => Guide.yticks(ticks=[3e6:1e6:6e6])}
        draw(PDF("plots/$prefix-ee-cumulative.pdf", 6inch, 4inch), plot(s[5:end,:], x="t", y="cumee", color="agent_type", Geom.smooth, yticks[:ee], Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-ee-smoothed.pdf", 6inch, 4inch), plot(s, x="t", y="ee", color="agent_type", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-throughput.pdf", 6inch, 4inch), plot(s[1:100:end, :], x="t", y="bits", color="agent_type", Geom.smooth, yticks[:th], Guide.xlabel("Time (s)"), Guide.ylabel("Throughput (packets)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-buffer.pdf", 6inch, 4inch), plot(s[1:100:end, :], x="t", y="buf", color="agent_type", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Buffer Occupancy (packets)"), Guide.colorkey("Algorithm"), theme))
        #gc()=#
    end
    #df[:ee] = df[:throughput] ./ df[:energy]
    return df
end

function plotframe(frame)
    for df = groupby(frame, [:n_good_channel, :pkt_max, :n_agent, :sharingperiod])
        title = string("n_good_channel=", df[:n_good_channel][1], " pkt_max=", df[:pkt_max][1], " nagent=", df[:n_agent][1], " period=", df[:sharingperiod][1])
        draw(SVGJS("th/beta/$title.svg", 10inch, 8inch), plot(df, y="throughput", x="beta_idle", color="agent_type", Geom.point, Geom.line, Guide.title(title)))
        draw(SVGJS("ee/beta/$title.svg", 10inch, 8inch), plot(df, y="ee", x="beta_idle", color="agent_type", Geom.point, Geom.line, Guide.title(title)))
    end
    for df = groupby(frame, [:beta_idle, :pkt_max, :n_agent, :sharingperiod])
        title = string("beta_idle=", df[:beta_idle][1], " pkt_max=", df[:pkt_max][1], " nagent=", df[:n_agent][1], " period=", df[:sharingperiod][1])
        draw(SVGJS("th/ngc/$title.svg", 10inch, 8inch), plot(df, y="throughput", x="n_good_channel", color="agent_type", Geom.point, Geom.line, Guide.title(title)))
        draw(SVGJS("ee/ngc/$title.svg", 10inch, 8inch), plot(df, y="ee", x="n_good_channel", color="agent_type", Geom.point, Geom.line, Guide.title(title)))
    end
end

function ee(d)
    p = DataFrame()
    for i in d[:agent_type]
       p[symbol(i)] = d[d[:agent_type] .== i, :bits][1] ./ d[d[:agent_type] .== i, :en][1]
    end
    p
end

getdata()

#df=getdata()
#plotframe(df)
function plot2(df)
    for d = groupby(df, [:prefix])
        s=DataFrame(agent_type=String[], en=Vector{Float64}[], t=Vector{Float64}[], bits=Vector{Float64}[], ee=Vector{Float64}[], cumee=Vector{Float64}[], cumth=Vector{Float64}[])
        for i=1:size(d)[2]
            ee = d[:bits][i] / d[:en][i]
            cumee = cumsum(ee)
            cumth = cumsum(d[:bits][i])
            append!(s, DataFrame(agent_type=fill(d[:agent_type][i], 30000), en=d[:en][i], t=d[:t][i], bits=d[:bits][i], ee=ee, cumee=cumee, cumth=cumth))
        end
        prefix = d[:prefix]
        draw(PNG("plots/$prefix-ee-cumulative.png", 10inch, 8inch), plot(s, x="t", y="cumee", color="agent_type", Geom.line))
        draw(PNG("plots/$prefix-throughput-cumulative.png", 10inch, 8inch), plot(s, x="t", y="cumee", color="agent_type", Geom.line))
        println(prefix)
    end
end
#plot2(df)
function extractQ(df)
    return df[df[:, :agent_type] .== "CooperativeQ",:]
end

function plotsingle(df)
    d=df[(df[:,:n_agent] .== 1) & (df[:,:sharingperiod] .== 1000) & (df[:,:pkt_max] .== 8),:]
    db = d[d[:,:n_good_channel] .== 3,:]
    s=DataFrame(beta_idle=ASCIIString[], en=Float64[], t=Int64[], bits=Float64[], ee=Float64[], cumee=Float64[], cumth=Float64[])
    for i=1:size(db)[1]
        b = vec(db[i,:bits])
        e = vec(db[i,:en])
        ee_ = b ./ e
        dd = DataFrame(beta_idle=convert(Vector{ASCIIString},([string(db[i, :beta_idle]) for x=1:30000])), en=e, t=[1:30000], bits=b, ee=ee_, cumee=cumsum(b) ./ cumsum(e), cumth=cumsum(b))
        append!(s, dd)
        @printf "beta idle %f\n" db[i, :beta_idle]
    end
    theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=0.6mm)
    draw(PDF("plots/effect-of-b_idle-th.pdf", 6inch, 4inch), plot(s[5:end,:], x="t", y="ee", color="beta_idle", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("b_idle"), theme))
    draw(PDF("plots/effect-of-b_idle-ee.pdf", 6inch, 4inch), plot(s, x="t", y="bits", color="beta_idle", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Throughput"), Guide.colorkey("b_idle"), theme))
    db = d[d[:,:beta_idle] .== 20,:]
    s=DataFrame(n_good_channel=ASCIIString[], en=Float64[], t=Int64[], bits=Float64[], ee=Float64[], cumee=Float64[], cumth=Float64[])
    for i=1:size(db)[1]
        b = vec(db[i,:bits])
        e = vec(db[i,:en])
        ee_ = b ./ e
        dd = DataFrame(n_good_channel=convert(Vector{ASCIIString},([string(db[i, :n_good_channel]) for x=1:30000])), en=e, t=[1:30000], bits=b, ee=ee_, cumee=cumsum(b) ./ cumsum(e), cumth=cumsum(b))
        append!(s, dd)
        @printf "ngc %d\n" db[i, :n_good_channel]
    end
    theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=0.6mm)
    draw(PDF("plots/effect-of-ngc-th.pdf", 6inch, 4inch), plot(s[5:end,:], x="t", y="ee", color="n_good_channel", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("# Type-I Channels"), theme))
    draw(PDF("plots/effect-of-ngc-ee.pdf", 6inch, 4inch), plot(s, x="t", y="bits", color="n_good_channel", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Throughput"), Guide.colorkey("# Type-I Channels"), theme))
end

function plotmulti(df)
    d=df[(df[:,:pkt_max] .== 8),:]
    db = d[(d[:,:n_agent] .== 7) & (d[:,:sharingperiod] .== 1000) & (d[:,:n_good_channel] .== 3),:]
    s=DataFrame(beta_idle=ASCIIString[], en=Float64[], t=Int64[], bits=Float64[], ee=Float64[], cumee=Float64[], cumth=Float64[])
    for i=1:size(db)[1]
        b = vec(db[i,:bits])
        e = vec(db[i,:en])
        ee_ = b ./ e
        dd = DataFrame(beta_idle=convert(Vector{ASCIIString},([string(db[i, :beta_idle]) for x=1:30000])), en=e, t=[1:30000], bits=b, ee=ee_, cumee=cumsum(b) ./ cumsum(e), cumth=cumsum(b))
        append!(s, dd)
        @printf "beta idle %f\n" db[i, :beta_idle]
    end
    theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=0.6mm)
    draw(PDF("plots/effect-of-b_idle-th.pdf", 6inch, 4inch), plot(s[5:end,:], x="t", y="ee", color="beta_idle", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("b_idle"), theme))
    draw(PDF("plots/effect-of-b_idle-ee.pdf", 6inch, 4inch), plot(s, x="t", y="bits", color="beta_idle", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Throughput"), Guide.colorkey("b_idle"), theme))
    
    db = d[(d[:,:n_agent] .== 7) & (d[:,:sharingperiod] .== 1000) & (d[:,:beta_idle] .== 8),:]
    s=DataFrame(n_good_channel=ASCIIString[], en=Float64[], t=Int64[], bits=Float64[], ee=Float64[], cumee=Float64[], cumth=Float64[])
    for i=1:size(db)[1]
        b = vec(db[i,:bits])
        e = vec(db[i,:en])
        ee_ = b ./ e
        dd = DataFrame(n_good_channel=convert(Vector{ASCIIString},([string(db[i, :n_good_channel]) for x=1:30000])), en=e, t=[1:30000], bits=b, ee=ee_, cumee=cumsum(b) ./ cumsum(e), cumth=cumsum(b))
        append!(s, dd)
        @printf "ngc %d\n" db[i, :n_good_channel]
    end
    theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=0.6mm)
    draw(PDF("plots/effect-of-ngc-th.pdf", 6inch, 4inch), plot(s[5:end,:], x="t", y="ee", color="n_good_channel", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("# Type-I Channels"), theme))
    draw(PDF("plots/effect-of-ngc-ee.pdf", 6inch, 4inch), plot(s, x="t", y="bits", color="n_good_channel", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Throughput"), Guide.colorkey("# Type-I Channels"), theme))

    db = d[(d[:,:n_agent] .== 7) & (d[:,:n_good_channel] .== 3) & (d[:,:beta_idle] .== 8),:]
    s=DataFrame(sharingperiod=ASCIIString[], en=Float64[], t=Int64[], bits=Float64[], ee=Float64[], cumee=Float64[], cumth=Float64[])
    for i=1:size(db)[1]
        b = vec(db[i,:bits])
        e = vec(db[i,:en])
        ee_ = b ./ e
        dd = DataFrame(sharingperiod=convert(Vector{ASCIIString},([string(db[i, :sharingperiod]) for x=1:30000])), en=e, t=[1:30000], bits=b, ee=ee_, cumee=cumsum(b) ./ cumsum(e), cumth=cumsum(b))
        append!(s, dd)
        @printf "sharingperiod %d\n" db[i, :sharingperiod]
    end
    theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=0.6mm)
    draw(PDF("plots/effect-of-sharingperiod-th.pdf", 6inch, 4inch), plot(s[5:end,:], x="t", y="ee", color="sharingperiod", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Sharing Period"), theme))
    draw(PDF("plots/effect-of-sharingperiod-ee.pdf", 6inch, 4inch), plot(s, x="t", y="bits", color="sharingperiod", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Throughput"), Guide.colorkey("Sharing Period"), theme))

    db = d[(d[:,:sharingperiod] .== 1000) & (d[:,:n_good_channel] .== 3) & (d[:,:beta_idle] .== 8),:]
    s=DataFrame(n_agent=ASCIIString[], en=Float64[], t=Int64[], bits=Float64[], ee=Float64[], cumee=Float64[], cumth=Float64[])
    for i=1:size(db)[1]
        b = vec(db[i,:bits])
        e = vec(db[i,:en])
        ee_ = b ./ e
        dd = DataFrame(n_agent=convert(Vector{ASCIIString},([string(db[i, :n_agent]) for x=1:30000])), en=e, t=[1:30000], bits=b, ee=ee_, cumee=cumsum(b) ./ cumsum(e), cumth=cumsum(b))
        append!(s, dd)
        @printf "n_agent %d\n" db[i, :n_agent]
    end
    theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=0.6mm)
    draw(PDF("plots/effect-of-n_agent-th.pdf", 6inch, 4inch), plot(s[5:end,:], x="t", y="ee", color="n_agent", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("# of Agents"), theme))
    draw(PDF("plots/effect-of-n_agent-ee.pdf", 6inch, 4inch), plot(s, x="t", y="bits", color="n_agent", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Throughput"), Guide.colorkey("# of Agents"), theme))
end