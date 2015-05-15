print("Loading modules...")

print("Util...")
using Util
print("Params...")
using Params
print("DataFrames...")
using DataFrames
print("DataStructures...")
using DataStructures: DefaultDict
print("JLD...")
using HDF5, JLD
print("Gadfly...")
using Gadfly

println("DONE")

#=
Extracts and categorizes the data from saved jld files.

Returns a DataFrame containing all sufficient statistics
=#
function getdata()
    df = DataFrame()
    df[:goodratio] = Float64[]
    df[:pkt_max] = Int[]
    df[:n_agent] = Int[]
    df[:agent_type] = String[]
    df[:generated_packets] = Float64[]
    df[:tried_packets] = Float64[]
    df[:sent_packets] = Float64[]
    df[:buf_levels] = Matrix{Float64}[]
    df[:buf_overflow] = Float64[]
    df[:en] = Vector{Float64}[]
    df[:bits] = Vector{Float64}[]
    df[:prefix] = String[]
    df[:t] = Vector{Float64}[]
    df[:latency] = Matrix{Float64}[]
    df[:latencyhist] = Matrix{Dict{Int, Int}}[]
    agent_types = ["CooperativeQ", "OptHighestSNR", "RandomChannel", "ContextQ"]
    for P = genparams()
        dir = joinpath("data/", P.prefix)
        if ! isdir(dir)
            continue
        end
        println("Processing ", P.prefix)
        # s=DataFrame(agent_type=ASCIIString[], buf=Float64[], en=Float64[], t=Int64[], bits=Float64[], ee=Float64[], cumee=Float64[], cumth=Float64[])
        for at in agent_types
            file = jldopen(joinpath(dir, "$at.jld"), "r")
            energy = read(file, "avg_energies")
            bits = read(file, "avg_bits")
            buf_overflow = read(file, "buf_overflows")
            buf_levels = read(file, "buf_levels")
            generated_packets = mean(read(file, "generated_packets"))
            tried_packets = mean(read(file, "tried_packets"))
            sent_packets = mean(read(file, "sent_packets"))
            ee = mean(bits)/mean(energy)
            latency = read(file, "latencies")
            extra = jldopen(joinpath(dir, "$at-extra.jld"), "r")
            latencyhist = read(extra, "latencyhist")
            d = {(P.goodratio[1] / P.goodratio[2]) P.pkt_max P.n_agent at generated_packets tried_packets sent_packets buf_levels buf_overflow vec(mean(energy, [1])) vec(mean(bits, [1])) P.prefix [1:30000] latency latencyhist}
            push!(df, d)
            b=vec(mean(bits, [1]))
            en=vec(mean(energy, [1]))
            ee_ = b ./ en
            #= dd = DataFrame(agent_type=fill(at, t_total), buf=vec(mean(read(file, "buf_matrix"), [1])), en=e, t=[1:t_total], bits=b, ee=ee_, cumee=cumsum(b) ./ cumsum(e), cumth=cumsum(b))
            append!(s, dd) =#
            close(file)
            avg_buf_overflow = mean(buf_overflow)
            avg_buf_levels = mean(buf_levels)
            println("$at\t$ee\t$avg_buf_levels\t$avg_buf_overflow")

        end
        prefix = P.prefix
        #= s[:t] .*= 10e-3
        theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=1mm, default_point_size=0.8mm)
        yticks = {:th => Guide.yticks(ticks=[1000:1000:7000]), :ee => Guide.yticks(ticks=[3e6:1e6:6e6])}
        draw(PDF("plots/$prefix-ee-cumulative.pdf", 6inch, 4inch), plot(s[5:end,:], x="t", y="cumee", color="agent_type", Geom.smooth, yticks[:ee], Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-ee-smoothed.pdf", 6inch, 4inch), plot(s, x="t", y="ee", color="agent_type", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-throughput.pdf", 6inch, 4inch), plot(s[1:100:end, :], x="t", y="bits", color="agent_type", Geom.smooth, yticks[:th], Guide.xlabel("Time (s)"), Guide.ylabel("Throughput (packets)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-buffer.pdf", 6inch, 4inch), plot(s[1:100:end, :], x="t", y="buf", color="agent_type", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Buffer Occupancy (packets)"), Guide.colorkey("Algorithm"), theme)) =#
    end
    df[:en_mean] = map(mean, df[:en])
    df[:en_std] = map(std, df[:en])
    df[:bits_mean] = map(mean, df[:bits])
    df[:bits_std] = map(std, df[:bits])
    ee = map(./, df[:bits], df[:en])
    df[:ee_mean] =  map(mean, ee)
    # retries per sent packet
    df[:retries] = (df[:tried_packets] ./ df[:sent_packets]) - 1
    df[:buf_mean] = map(mean, df[:buf_levels])
    df[:buf_max] = map(maximum, df[:buf_levels])
    df[:buf_std] = map(std, df[:buf_levels])
    df[:latency_mean] = map(mean, df[:latency])
    df[:latency_std] = map(std, df[:latency])
    df[:latency_max] = map(maximum, df[:latency])
    df
end

#=
Save sufficient statistics
=#
function savestats(df)
    stats = copy(df)
    for key in [:en, :bits, :t, :buf_levels, :latency]
        delete!(stats, key)
    end
    # save whole statistics
    writetable("suffstats.csv", stats)
end

# function plotframe(frame)
#     theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=1mm, default_point_size=0.8mm)
#     for df = groupby(frame, [:n_good_channel, :pkt_max, :n_agent, :sharingperiod])
#         title = string("n_good_channel=", df[:n_good_channel][1], " pkt_max=", df[:pkt_max][1], " nagent=", df[:n_agent][1], " period=", df[:sharingperiod][1])
#         draw(SVGJS("th/beta/$title.svg", 10inch, 8inch), plot(df, y="throughput", x="beta_idle", color="agent_type", Geom.point, Geom.line, Guide.title(title)))
#         draw(SVGJS("ee/beta/$title.svg", 10inch, 8inch), plot(df, y="ee", x="beta_idle", color="agent_type", Geom.point, Geom.line, Guide.title(title)))
#     end
#     for df = groupby(frame, [:beta_idle, :pkt_max, :n_agent, :sharingperiod])
#         title = string("beta_idle=", df[:beta_idle][1], " pkt_max=", df[:pkt_max][1], " nagent=", df[:n_agent][1], " period=", df[:sharingperiod][1])
#         draw(SVGJS("th/ngc/$title.svg", 10inch, 8inch), plot(df, y="throughput", x="n_good_channel", color="agent_type", Geom.point, Geom.line, Guide.title(title)))
#         draw(SVGJS("ee/ngc/$title.svg", 10inch, 8inch), plot(df, y="ee", x="n_good_channel", color="agent_type", Geom.point, Geom.line, Guide.title(title)))
#     end
# end

# function ee(d)
#     p = DataFrame()
#     for i in d[:agent_type]
#        p[symbol(i)] = d[d[:agent_type] .== i, :bits][1] ./ d[d[:agent_type] .== i, :en][1]
#     end
#     p
# end

function plotframes(df)
    theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=1mm, default_point_size=0.8mm)
    yticks = {:th => Guide.yticks(ticks=[1000:1000:7000]), :ee => Guide.yticks(ticks=[3e6:1e6:6e6])}
    for data in groupby(df, :prefix)
        prefix = data[1, :prefix]
        println("Plotting $prefix")
        function sumlatencies(latencies)
            lat = DefaultDict(Int, Int, 0)
            for l in latencies
                for (k, v) in l
                    lat[k] += v
                end
            end
            highest = 0
            latarray = zeros(Float64, sum(map(i -> i[2], lat)))
            i = 1
            @inbounds for (k, v) in lat
                latarray[i:i+v-1] = k
                i += v
                highest = max(highest, v)
            end
            highest, latarray
        end
        highest = 0
        d = by(data, :agent_type) do df
            δ=DataFrame()
            δ[:agent_type] = ASCIIString[]
            δ[:latency] = Float64[]
            for i in size(df)[1]
                maxi, l = sumlatencies(df[i, :latencyhist])
                highest = max(highest, maxi)
                Δ = DataFrame(agent_type=fill(df[i, :agent_type], length(l)), latency=l)
                append!(δ, Δ)
            end
            δ
        end
        # Plot latency histograms
        latencyhist = plot(d, x="latency", color="agent_type", Geom.histogram(position=:dodge, bincount=10), Guide.xlabel("Latency (time slots)"), Guide.colorkey("Algorithm"), theme, Guide.yticks(ticks=linspace(0, highest * 2, 5)))
        draw(SVGJS("$prefix-latency-histogram.svg", 10inch, 6inch), latencyhist)
        # draw(PDF("plots/$prefix-ee-cumulative.pdf", 6inch, 4inch), plot(data, x="t", y="cumee", color="agent_type", Geom.smooth, yticks[:ee], Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Algorithm"), theme))
        # draw(PDF("plots/$prefix-ee-smoothed.pdf", 6inch, 4inch), plot(data, x="t", y="ee", color="agent_type", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Algorithm"), theme))
        # draw(PDF("plots/$prefix-throughput.pdf", 6inch, 4inch), plot(data, x="t", y="bits", color="agent_type", Geom.smooth, yticks[:th], Guide.xlabel("Time (s)"), Guide.ylabel("Throughput (packets)"), Guide.colorkey("Algorithm"), theme))
        # draw(PDF("plots/$prefix-buffer.pdf", 6inch, 4inch), plot(data, x="t", y="buf", color="agent_type", Geom.smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Buffer Occupancy (packets)"), Guide.colorkey("Algorithm"), theme))
    end
end

#df = getdata()
#savestats(df)
plotframes(df)