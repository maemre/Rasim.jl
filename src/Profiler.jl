println("Loading modules")
using Params,Rasim,ProfileView
#=println("Initialization")
Profile.init(10000000, 0.002)=#
p=genparams()
println("Pre-run")
Rasim.run_whole_simulation(p[end])
#println("Timing")
#@time [Rasim.run_whole_simulation(p[end/2]) for i=1]
#= println("Profiling")
@profile Rasim.run_whole_simulation(p)
ProfileView.view()
readline()=#