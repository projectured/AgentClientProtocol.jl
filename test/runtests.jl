using Test
using AgentClientProtocol
import AgentClientProtocol as ACP

@testset "AgentClientProtocol" begin
    include("objects.jl")
    include("connection.jl")
    Sys.isunix() && include("process.jl")
end
