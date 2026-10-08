# The handlers: what each side answers. A client gives a `ClientHandler`, an
# agent gives an `AgentHandler`, and each adds a method of `answer_request` and of
# `receive_notification` for each message of the other side that it serves.

"""
    ClientHandler

The supertype of the handler of a client. A client adds a method of
[`answer_request`](@ref) for each request of the agent that it serves, such as
`RequestPermissionRequest`, and a method of [`receive_notification`](@ref) for
`SessionNotification`. A request that the client does not serve gets the
error [`METHOD_NOT_FOUND`](@ref).
"""
abstract type ClientHandler end

"""
    AgentHandler

The supertype of the handler of an agent. An agent adds a method of
[`answer_request`](@ref) for each request of the client that it serves, such as
`InitializeRequest`, `NewSessionRequest` and `PromptRequest`, and a method of
[`receive_notification`](@ref) for `CancelNotification`. A request that the
agent does not serve gets the error [`METHOD_NOT_FOUND`](@ref).
"""
abstract type AgentHandler end

"""
    answer_request(handler, request::ProtocolObject, context::RequestContext)
    answer_request(handler, method::String, params::Dict{String,Any}, context::RequestContext)

Answer a request of the other side. The first method gets a request of the
protocol, and gives its response: a value of the response type of the method,
a plain JSON object, or `nothing` for an empty object. The second method gets a
request whose method the protocol does not name, such as an extension method
whose name starts with `_`, and gives a plain JSON value.

A method of a handler types its request argument, and leaves the other
arguments untyped or types them as the defaults do.

Each request runs on a task of its own, so a handler can wait, for example for a
person. `context.connection` sends requests and notifications to the other
side. To answer with an error, throw a [`ProtocolException`](@ref). Any other
exception answers with [`INTERNAL_ERROR`](@ref) and a message that does not
quote it.
"""
answer_request(handler, request::ProtocolObject, context) =
    throw(ProtocolException(METHOD_NOT_FOUND, "The method `$(context.method)` is not served."))

answer_request(handler, method::String, params, context) =
    throw(ProtocolException(METHOD_NOT_FOUND, "The method `$(method)` is not served."))

"""
    receive_notification(handler, notification::ProtocolObject, connection::Connection)
    receive_notification(handler, method::String, params::Dict{String,Any}, connection::Connection)

Receive a notification of the other side. The second method gets a notification
whose method the protocol does not name. A notification that the handler does
not serve is dropped.

Notifications run on the task that reads the connection, in the order in which
the other side sent them, so a handler must not wait.
"""
receive_notification(handler, notification::ProtocolObject, connection) = nothing
receive_notification(handler, method::String, params, connection) = nothing

# The type of the request or notification of `method` that `handler` receives,
# or `nothing` for a method that the protocol does not name.
_find_method_type(::ClientHandler, method::String) =
    get(CLIENT_METHOD_TYPES, method, get(PROTOCOL_METHOD_TYPES, method, nothing))
_find_method_type(::AgentHandler, method::String) =
    get(AGENT_METHOD_TYPES, method, get(PROTOCOL_METHOD_TYPES, method, nothing))
_find_method_type(handler, method::String) = get(PROTOCOL_METHOD_TYPES, method, nothing)

"""
    send_session_update!(connection, session_id, update::SessionUpdate)

Send an update of a session to the client, with the notification
`session/update`. An agent sends the chunks of its answer, its tool calls and
its plan so.
"""
send_session_update!(connection::Connection, session_id::AbstractString, update::SessionUpdate) =
    send_notification!(connection, SessionNotification(session_id = session_id, update = update))
