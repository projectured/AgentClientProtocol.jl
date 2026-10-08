# The connection: JSON-RPC 2.0 over two streams, one message on each line. Each
# side sends requests and notifications, and answers the requests of the other
# side with its handler. A connection can start the other side as a process,
# and it ends that process and every process that it started.

"""
    PROTOCOL_VERSION

The version of the Agent Client Protocol that this package speaks, which a
client sends in `initialize`.
"""
const PROTOCOL_VERSION = 1

"""
    ProtocolException(code, message; data = nothing)

The error answer of a JSON-RPC request. `send_request!` throws it when the
other side answers with an error, or when the connection closes first. A handler
throws it to answer a request with an error. The codes of the protocol are
constants: [`METHOD_NOT_FOUND`](@ref), [`INVALID_PARAMS`](@ref),
[`INTERNAL_ERROR`](@ref), [`REQUEST_CANCELLED`](@ref),
[`AUTHENTICATION_REQUIRED`](@ref) and others.
"""
struct ProtocolException <: Exception
    code::Int
    message::String
    data::Any
end

ProtocolException(code::Integer, message::AbstractString; data = nothing) =
    ProtocolException(Int(code), String(message), data)

Base.showerror(io::IO, exception::ProtocolException) =
    print(io, "ProtocolException: ", exception.message, " (code ", exception.code, ")")

"""
    Connection

One side of a connection: the two streams, the requests that wait for an
answer, the requests of the other side that wait for their answer, and the task
that reads. [`open_connection`](@ref) makes one, and
[`close_connection!`](@ref) ends it. `wait(connection)` waits until the other
side closes its stream.

The handler of the connection answers what the other side sends: a
[`ClientHandler`](@ref) on the client side, an [`AgentHandler`](@ref) on the
agent side.
"""
mutable struct Connection
    handler::Any
    incoming::IO
    outgoing::IO
    process::Union{Nothing,Base.Process}
    process_id::Int32
    write_lock::ReentrantLock
    state_lock::ReentrantLock
    waiting_answers::Dict{Int,Channel{Dict{String,Any}}}
    answering::Dict{Any,Any}
    next_id::Int
    is_closed::Bool
    reader::Union{Nothing,Task}
end

"""
    open_connection(handler, incoming::IO, outgoing::IO) -> Connection
    open_connection(handler, command::Cmd; log_line) -> Connection

Open a connection that reads the messages of the other side from `incoming`
and writes its own messages to `outgoing`. An agent program serves its client
with `open_connection(handler, stdin, stdout)`.

The second method starts `command` as the other side, in a process group of
its own, and talks over its standard input and output. Each line that the
process writes to its standard error goes to `log_line`, which writes it to the
debug log when the caller gives no other function. The end of the process
closes the connection.
"""
function open_connection(handler, incoming::IO, outgoing::IO;
                         process::Union{Nothing,Base.Process} = nothing)
    connection = Connection(handler, incoming, outgoing, process,
                            process === nothing ? Int32(0) : Int32(getpid(process)),
                            ReentrantLock(), ReentrantLock(), Dict{Int,Channel{Dict{String,Any}}}(),
                            Dict{Any,Any}(), 0, false, nothing)
    connection.reader = errormonitor(@async _read_messages(connection))
    connection
end

function open_connection(handler, command::Cmd; log_line::Function = _log_debug_line)
    errors = Pipe()
    process = open(pipeline(Cmd(command; detach = true); stderr = errors), "r+")
    close(errors.in)
    errormonitor(@async _read_error_lines(errors, log_line))
    connection = open_connection(handler, process.out, process.in; process)
    # A child of the process can keep the output open after the process ends, so
    # the end of the process closes the connection.
    errormonitor(@async (wait(process); close_connection!(connection)))
    connection
end

_log_debug_line(line) = @debug "The other side of an ACP connection wrote to its standard error." line

function _read_error_lines(errors::IO, log_line::Function)
    for line in eachline(errors)
        try
            log_line(line)
        catch exception
            @warn "A line of standard error could not be logged." exception
        end
    end
end

"""
    is_connection_open(connection) -> Bool

Whether the connection can carry a message: it is not closed, and the other
side did not close its stream.
"""
is_connection_open(connection::Connection) =
    !connection.is_closed && (connection.reader === nothing || !istaskdone(connection.reader))

"""
    close_connection!(connection) -> connection

Close the connection. The outgoing stream closes, so the other side sees the
end of its input. A process that the connection started and that still runs
after five seconds gets `SIGTERM`, and after two more seconds `SIGKILL`, sent to
its whole process group. The group gets `SIGTERM` at the end in any case, so no
child of the process lives on. Each request that waits for an answer throws a
[`ProtocolException`](@ref).
"""
function close_connection!(connection::Connection)
    was_closed = lock(connection.state_lock) do
        was_closed = connection.is_closed
        connection.is_closed = true
        was_closed
    end
    was_closed && return connection
    lock(connection.write_lock) do
        try
            close(connection.outgoing)
        catch exception
            exception isa Base.IOError || rethrow()
        end
    end
    process = connection.process
    if process !== nothing
        if timedwait(() -> process_exited(process), 5.0) !== :ok
            _signal_process_group!(connection, Base.SIGTERM)
            timedwait(() -> process_exited(process), 2.0) === :ok ||
                _signal_process_group!(connection, Base.SIGKILL)
        end
        _signal_process_group!(connection, Base.SIGTERM)
    end
    _fail_waiting_requests!(connection)
    connection
end

"""
    wait(connection::Connection)

Wait until the other side closes its stream, or the connection closes.
"""
function Base.wait(connection::Connection)
    reader = connection.reader
    reader === nothing || wait(reader)
    nothing
end

# The process starts in a group of its own, so the group is the process and
# every process that it started, and the group outlives a process whose children
# still run. A group with no process left answers the signal with `ESRCH`.
function _signal_process_group!(connection::Connection, signal::Integer)
    if Sys.isunix()
        connection.process_id > 0 && ccall(:kill, Cint, (Cint, Cint), -connection.process_id, signal)
    else
        process = connection.process
        process === nothing || process_exited(process) || kill(process, signal)
    end
    nothing
end

function _fail_waiting_requests!(connection::Connection)
    channels = lock(() -> collect(values(connection.waiting_answers)), connection.state_lock)
    for channel in channels
        isready(channel) || put!(channel, Dict{String,Any}("error" => Dict{String,Any}(
            "code" => INTERNAL_ERROR, "message" => "The connection closed before the answer came.")))
    end
end

# --- Requests and notifications ----------------------------------------------

"""
    OutgoingRequest

A request that this side sent and whose answer can still come.
[`wait_for_answer`](@ref) waits for it, and [`cancel_request!`](@ref) asks the
other side to stop work on it.
"""
struct OutgoingRequest
    connection::Connection
    id::Int
    method::String
    answer::Channel{Dict{String,Any}}
    response_type::Type
end

"""
    start_request!(connection, request::ProtocolObject) -> OutgoingRequest
    start_request!(connection, method::AbstractString, params) -> OutgoingRequest

Send a request, and do not wait for its answer. The first method takes a
request type of the protocol, and its answer has the response type of the
method. The second method sends any method, such as an extension method whose
name starts with `_`, and its answer is a plain JSON value.
"""
start_request!(connection::Connection, request::ProtocolObject) =
    _start_request!(connection, get_method_name(typeof(request)), get_json(request),
                    get_response_type(typeof(request)))

start_request!(connection::Connection, method::AbstractString, params) =
    _start_request!(connection, String(method), convert_to_json(params), Any)

function _start_request!(connection::Connection, method::String, params, response_type::Type)
    answer = Channel{Dict{String,Any}}(1)
    id = lock(connection.state_lock) do
        connection.is_closed && throw(ProtocolException(INTERNAL_ERROR, "The connection is closed."))
        connection.next_id += 1
        connection.waiting_answers[connection.next_id] = answer
        connection.next_id
    end
    request = OutgoingRequest(connection, id, method, answer, response_type)
    try
        _write_message!(connection, Dict{String,Any}(
            "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    catch
        _forget_request!(request)
        rethrow()
    end
    request
end

"""
    wait_for_answer(request::OutgoingRequest; timeout = Inf)

Wait for the answer of a request, and return its result. Throws a
[`ProtocolException`](@ref) for an error answer, or when the connection closes
first. A finite `timeout`, in seconds, throws an error when no answer comes in
time; the request then stays open on the other side.
"""
function wait_for_answer(request::OutgoingRequest; timeout::Real = Inf)
    try
        if isfinite(timeout)
            timedwait(() -> isready(request.answer), Float64(timeout); pollint = 0.05) === :ok ||
                error("The answer of `$(request.method)` did not come in $(timeout) s.")
        end
        answer = take!(request.answer)
        if haskey(answer, "error")
            failure = answer["error"]
            failure isa AbstractDict || (failure = Dict{String,Any}())
            code = get(failure, "code", INTERNAL_ERROR)
            throw(ProtocolException(code isa Integer ? Int(code) : INTERNAL_ERROR,
                                    string(get(failure, "message", "The other side answered an error.")),
                                    get(failure, "data", nothing)))
        end
        convert_from_json(request.response_type, get(answer, "result", nothing))
    finally
        _forget_request!(request)
    end
end

_forget_request!(request::OutgoingRequest) =
    lock(() -> delete!(request.connection.waiting_answers, request.id), request.connection.state_lock)

"""
    send_request!(connection, request::ProtocolObject; timeout = Inf)
    send_request!(connection, method::AbstractString, params; timeout = Inf)

Send a request and wait for its answer: [`start_request!`](@ref) and then
[`wait_for_answer`](@ref).
"""
send_request!(connection::Connection, arguments...; timeout::Real = Inf) =
    wait_for_answer(start_request!(connection, arguments...); timeout)

"""
    cancel_request!(request::OutgoingRequest)

Ask the other side to stop work on a request, with the notification
`\$/cancel_request`. The other side still answers the request, with a result or
with the error [`REQUEST_CANCELLED`](@ref), so a task that waits for the answer
goes on waiting for it.
"""
function cancel_request!(request::OutgoingRequest)
    isready(request.answer) && return nothing
    send_notification!(request.connection, CancelRequestNotification(request_id = request.id))
    nothing
end

"""
    send_notification!(connection, notification::ProtocolObject)
    send_notification!(connection, method::AbstractString, params)

Send a notification, which has no answer.
"""
send_notification!(connection::Connection, notification::ProtocolObject) =
    send_notification!(connection, get_method_name(typeof(notification)), get_json(notification))

send_notification!(connection::Connection, method::AbstractString, params) =
    _write_message!(connection, Dict{String,Any}(
        "jsonrpc" => "2.0", "method" => String(method), "params" => convert_to_json(params)))

function _write_message!(connection::Connection, message::Dict{String,Any})
    text = JSON.json(message)
    lock(connection.write_lock) do
        connection.is_closed && throw(ProtocolException(INTERNAL_ERROR, "The connection is closed."))
        write(connection.outgoing, text, '\n')
        flush(connection.outgoing)
    end
    nothing
end

# --- The requests of the other side ------------------------------------------

"""
    RequestContext

A request of the other side while its handler answers it: the connection, the
JSON-RPC id, and whether the other side withdrew the request with
`\$/cancel_request`. See [`is_request_cancelled`](@ref) and
[`add_cancel_callback!`](@ref).
"""
mutable struct RequestContext
    connection::Connection
    id::Any
    method::String
    is_cancelled::Bool
    cancel_callbacks::Vector{Any}
end

"""
    is_request_cancelled(context::RequestContext) -> Bool

Whether the other side withdrew the request with `\$/cancel_request`.
"""
is_request_cancelled(context::RequestContext) =
    lock(() -> context.is_cancelled, context.connection.state_lock)

"""
    add_cancel_callback!(callback, context::RequestContext)

Call `callback()` when the other side withdraws the request. When it withdrew
the request already, `callback()` runs at once. A handler that waits for a
person uses it to stop the wait.
"""
function add_cancel_callback!(callback, context::RequestContext)
    is_cancelled = lock(context.connection.state_lock) do
        context.is_cancelled || push!(context.cancel_callbacks, callback)
        context.is_cancelled
    end
    is_cancelled && callback()
    nothing
end

# Read one message on each line until the other side closes its stream. A line
# that is not JSON is dropped with a warning that does not quote it.
function _read_messages(connection::Connection)
    try
        while true
            line = readline(connection.incoming)
            if isempty(line)
                eof(connection.incoming) && break
                continue
            end
            message = try
                read_json(line)
            catch exception
                exception isa ArgumentError || rethrow()
                @warn "The other side of an ACP connection wrote a line that is not JSON."
                continue
            end
            message isa Dict{String,Any} && _dispatch_message!(connection, message)
        end
    catch exception
        connection.is_closed || exception isa Base.IOError || exception isa EOFError ||
            @warn "The reader of an ACP connection stopped." exception
    finally
        _fail_waiting_requests!(connection)
    end
end

function _dispatch_message!(connection::Connection, message::Dict{String,Any})
    if haskey(message, "method")
        method = string(message["method"])
        params = get(message, "params", nothing)
        params isa Dict{String,Any} || (params = Dict{String,Any}())
        if haskey(message, "id")
            context = RequestContext(connection, message["id"], method, false, Any[])
            lock(() -> connection.answering[context.id] = context, connection.state_lock)
            errormonitor(@async _answer_request!(connection, context, params))
        else
            _receive_notification!(connection, method, params)
        end
    elseif haskey(message, "id")
        id = message["id"]
        answer = lock(() -> id isa Integer ? get(connection.waiting_answers, Int(id), nothing) : nothing,
                      connection.state_lock)
        answer === nothing || isready(answer) || put!(answer, message)
    end
    nothing
end

# A notification runs on the reader task, in the order of the messages, so a
# handler must not wait. `$/cancel_request` withdraws a request of the other side
# before the handler sees it.
function _receive_notification!(connection::Connection, method::String, params::Dict{String,Any})
    try
        type = _find_method_type(connection.handler, method)
        if type === nothing
            receive_notification(connection.handler, method, params, connection)
        else
            notification = _check_required_fields(convert_from_json(type, params))
            notification isa CancelRequestNotification && _withdraw_request!(connection, notification.request_id)
            receive_notification(connection.handler, notification, connection)
        end
    catch exception
        @warn "A notification of the other side of an ACP connection failed." method exception
    end
    nothing
end

function _withdraw_request!(connection::Connection, id)
    callbacks = lock(connection.state_lock) do
        context = get(connection.answering, id, nothing)
        (context === nothing || context.is_cancelled) && return Any[]
        context.is_cancelled = true
        callbacks = copy(context.cancel_callbacks)
        empty!(context.cancel_callbacks)
        callbacks
    end
    for callback in callbacks
        try
            callback()
        catch exception
            @warn "A cancel callback failed." exception
        end
    end
end

function _answer_request!(connection::Connection, context::RequestContext, params::Dict{String,Any})
    method = context.method
    answer = try
        type = _find_method_type(connection.handler, method)
        result = if type === nothing
            answer_request(connection.handler, method, params, context)
        else
            request = try
                _check_required_fields(convert_from_json(type, params))
            catch exception
                exception isa ArgumentError || rethrow()
                throw(ProtocolException(INVALID_PARAMS, sprint(showerror, exception)))
            end
            _write_result(type, answer_request(connection.handler, request, context))
        end
        Dict{String,Any}("jsonrpc" => "2.0", "id" => context.id, "result" => convert_to_json(result))
    catch exception
        failure = exception isa ProtocolException ? exception :
                  ProtocolException(INTERNAL_ERROR, "The answer to `$(method)` failed.")
        exception isa ProtocolException ||
            @warn "The handler of an ACP connection failed to answer a request." method exception
        error_ = Dict{String,Any}("code" => failure.code, "message" => failure.message)
        failure.data === nothing || (error_["data"] = convert_to_json(failure.data))
        Dict{String,Any}("jsonrpc" => "2.0", "id" => context.id, "error" => error_)
    finally
        lock(() -> delete!(connection.answering, context.id), connection.state_lock)
    end
    try
        connection.is_closed || _write_message!(connection, answer)
    catch exception
        exception isa ProtocolException || exception isa Base.IOError || rethrow()
    end
    nothing
end

# The result of a request of the protocol: an empty object when the handler
# gives `nothing` for a response type that is an object.
function _write_result(type::Type, result)
    response_type = get_response_type(type)
    result === nothing && response_type <: ProtocolObject && return Dict{String,Any}()
    _write_member(response_type, result)
end
