println("Loading modules")
using Params,Rasim,ProfileView
println("Initialization")
Profile.init(10000000, 0.002)
p=genparams()[1]
println("Pre-run")
Rasim.run_whole_simulation(p)
#=println("Timing")
@time [Rasim.run_whole_simulation(p) for i=1:10]=#
println("Profiling")
@profile Rasim.run_whole_simulation(p)
ProfileView.view()
readline()