module Movement

import Params
export Point, randomwalk

type Point{T}
    x :: T
    y :: T
end

function Point{T}(arr :: Array{T, 1})
    if length(arr) != 2
        error("Points are in 2D.")
    end
    new(arr[1], arr[2])
end

function Point(T :: DataType)
    Point(zero(T), zero(T))
end

+(a :: Point, b :: Point) = Point(a.x+b.x, a.y+b.y)

#=
Return a function that makes a random walk according to a
Wiener process with given parameters.

Parameters:

- speed: Speed of random walk (m/s)
- unit_interval: Interval of a jump (timeslots)

Returns:
- a function that returns the difference (dx, dy) of random walk

=#
function randomwalk(speed :: Float64, unit_interval :: Int64)
    unit_speed :: Float64 = speed * sqrt(Params.t_slot)
    phi :: Float64 = rand() * 2*pi
    return t -> begin
        r = unit_speed * randn()
        if t % unit_interval == 0
            phi = rand() * 2*pi
        end
        return Point(r*cos(phi), r*sin(phi))
    end
end

end