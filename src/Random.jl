module Random

export randint, randgen

function randint{T}(min :: T, max :: T)
    convert(T, rand(T) % (max - min) + min)
end

#= 
 Generate a random indexes from a given cdf. Just like
 randgen in cmpe 547.
 =#
function randgen(prob :: Array{Float64}, n :: Int)
    # or make a binary search in given table
    vec(sum(broadcast(.<, repmat(vec(prob), 1, n), rand(1, n)), 1)) + 1
end

function randgen(prob :: Array{Float64})
    convert(Int, sum(vec(prob) .< rand(1))) + 1
end

#= 
 Generate a random indexes from a given cdf. Just like
 randgen in cmpe 547.
 =#
function randgen!(dest, prob :: Array{Float64}, n :: Int)
    vec(sum!(dest, broadcast(.<, repmat(vec(prob), 1, n), rand(1, n)), 1)) + 1
end

end