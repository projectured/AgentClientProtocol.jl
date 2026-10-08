"""
    AgentClientProtocol

The Agent Client Protocol (ACP) in Julia: the types of the protocol, and a
connection that serves the client side or the agent side over two streams.

ACP connects an editor, the *client*, to a coding agent, the *agent*. The two
sides exchange JSON-RPC 2.0 messages, one message on each line, usually over the
standard input and output of the agent process. See
<https://agentclientprotocol.com>.

- The types of the protocol, such as `PromptRequest` and `SessionUpdate`, are
  generated from the schema of the protocol. Each one is a view of a JSON
  object: see [`ProtocolObject`](@ref). They are public, but the module does
  not export them, because many of their names are short.
- [`open_connection`](@ref) connects to the other side, and a handler answers
  what the other side sends: see [`ClientHandler`](@ref),
  [`AgentHandler`](@ref), [`answer_request`](@ref) and
  [`receive_notification`](@ref).
- [`send_request!`](@ref) and [`send_notification!`](@ref) send to the other
  side.
"""
module AgentClientProtocol

using JSON

export ProtocolObject, get_json, convert_from_json, convert_to_json, read_json, write_json
export get_method_name, get_response_type

include("objects.jl")
include("types.jl")

end # module AgentClientProtocol
