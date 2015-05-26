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
    df[:en_idle] = Float64[]
    df[:en_sw] = Float64[]
    df[:en_sense] = Float64[]
    # df[:en_sleep] = Float64[]
    df[:en_tx] = Float64[]
    df[:delta] = Float64[]
    df[:b_idle] = Float64[]
    df[:d_svd] = Int[]
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
            energy = vec(mean(read(file, "avg_energies"), [1]))
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
            energies = jldopen(joinpath(dir, "$at-energies.jld"), "r")
            en_total = mean(energy)
            en_idle = mean(vec(mean(read(energies, "en_idle"), [1]))) / en_total
            en_sw = mean(vec(mean(read(energies, "en_sw"), [1]))) / en_total
            en_sense = mean(vec(mean(read(energies, "en_sense"), [1]))) / en_total
            # en_sleep = mean(vec(mean(read(energies, "en_sleep"), [1]))) / en_total
            en_tx = mean(vec(mean(read(energies, "en_tx"), [1]))) / en_total
            close(energies)
            d = {
                (P.goodratio[1] / P.goodratio[2])
                P.pkt_max
                P.n_agent
                at
                generated_packets
                tried_packets
                sent_packets
                buf_levels
                buf_overflow
                energy
                vec(mean(bits, [1]))
                P.prefix
                [1:Params.t_total]
                latency
                latencyhist
                en_idle
                en_sw
                en_sense
                #en_sleep
                en_tx
                P.δ
                P.beta_idle
                P.d_svd
            }
            push!(df, d)
            b=vec(mean(bits, [1]))
            en=vec(mean(energy, [1]))
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
    df[:ee] = ee
    df[:ee_cum] = map(./, map(cumsum, df[:bits]), map(cumsum, df[:en]))
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
    for key in [:en, :bits, :t, :buf_levels, :latency, :latencyhist, :ee, :ee_cum]
        delete!(stats, key)
    end
    # save whole statistics
    writetable("suffstats.csv", stats)
end

function plotframes(df)
    theme = Theme(major_label_font_size=6mm, minor_label_font_size=4mm, key_title_font_size=6mm, key_label_font_size=4mm, line_width=1mm, default_point_size=0.8mm)
    yticks = {:th => Guide.yticks(ticks=[1000:1000:7000]), :ee => Guide.yticks(ticks=[3e6:1e6:6e6])}
    for data in groupby(df, :prefix)
        prefix = data[1, :prefix]
        println("Plotting $prefix")
        ∇ = DataFrame(agent_type=ASCIIString[], ee=Float64[], ee_cum=Float64[], bits=Float64[], t=Float64[], buf_levels=Float64[])
        for i=1:size(data)[1]
            dd = DataFrameRow(data, i)
            append!(∇, DataFrame(agent_type=fill(dd[:agent_type], length(dd[:ee])), ee=dd[:ee], ee_cum=dd[:ee_cum], bits=dd[:bits], t=dd[:t], buf_levels=vec(mean(dd[:buf_levels], 1))))
        end
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
        println("Plotting Latency histogram")
        # Plot latency histograms
        latencyhist = plot(d, x="latency", color="agent_type", Geom.histogram(position=:dodge, bincount=10), Guide.xlabel("Latency (time slots)"), Guide.colorkey("Algorithm"), theme, Guide.yticks(ticks=linspace(0, highest * 2, 5)))
        draw(PDF("plots/$prefix-latency-histogram.pdf", 10inch, 6inch), latencyhist)
        smooth = Geom.smooth(smoothing=0.2)
        println("Plotting other plots")
        draw(PDF("plots/$prefix-ee-cumulative.pdf", 6inch, 4inch), plot(∇, x="t", y="ee_cum", color="agent_type", smooth, yticks[:ee], Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-ee-smoothed.pdf", 6inch, 4inch), plot(∇, x="t", y="ee", color="agent_type", smooth, Guide.xlabel("Time (s)"), Guide.ylabel("EE (b/J)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-throughput.pdf", 6inch, 4inch), plot(∇, x="t", y="bits", color="agent_type", smooth, yticks[:th], Guide.xlabel("Time (s)"), Guide.ylabel("Throughput (packets)"), Guide.colorkey("Algorithm"), theme))
        draw(PDF("plots/$prefix-buffer.pdf", 6inch, 4inch), plot(∇, x="t", y="buf_levels", color="agent_type", smooth, Guide.xlabel("Time (s)"), Guide.ylabel("Buffer Occupancy (packets)"), Guide.colorkey("Algorithm"), theme))
    end
end

df = getdata()
println("Saving statistics")
savestats(df)
plotframes(df)