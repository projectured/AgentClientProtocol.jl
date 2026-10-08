# AgentClientProtocol.jl

[![CI](https://github.com/projectured/AgentClientProtocol.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/projectured/AgentClientProtocol.jl/actions/workflows/CI.yml)

AgentClientProtocol is the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) in Julia. ACP connects an editor, the *client*, to a coding agent, the
*agent*. The two sides send JSON-RPC 2.0 messages, one message on each line,
usually over the standard input and output of the agent process.

The package serves both sides:

- **A client** starts an agent, opens sessions, sends prompts, and shows what
  the agent sends back: text, reasoning, tool calls, plans, and questions for
  the person.
- **An agent** answers the requests of an editor, and sends the updates of its
  sessions.

It has one dependency, JSON.jl, and needs no other runtime.

## Install

AgentClientProtocol is in the registry
[`ProjecturedRegistry`](https://github.com/projectured/ProjecturedRegistry), not in
the General registry. Add both registries once; if General is there already, its
line does nothing:

```
pkg> registry add General
pkg> registry add https://github.com/projectured/ProjecturedRegistry
pkg> add AgentClientProtocol
```

## A client

A client gives a handler, which answers what the agent sends, and starts the
agent as a process:

```julia
using AgentClientProtocol
import AgentClientProtocol as ACP

struct MyClient <: ClientHandler end

# Show each update of a session: a chunk of text, a tool call, a plan, ...
function ACP.receive_notification(::MyClient, notification::ACP.SessionNotification, connection)
    update = notification.update
    update isa ACP.AgentMessageChunk && update.content isa ACP.TextContent &&
        print(update.content.text)
end

# Answer a question of the agent. This client always takes the first option.
ACP.answer_request(::MyClient, request::ACP.RequestPermissionRequest, context) =
    ACP.RequestPermissionResponse(
        outcome = ACP.SelectedPermissionOutcome(option_id = first(request.options).option_id))

connection = open_connection(MyClient(), `my-agent --acp`)
send_request!(connection, ACP.InitializeRequest(protocol_version = PROTOCOL_VERSION))
session = send_request!(connection, ACP.NewSessionRequest(cwd = pwd(), mcp_servers = []))
answer = send_request!(connection, ACP.PromptRequest(
    session_id = session.session_id, prompt = [ACP.TextContent(text = "Explain this project.")]))
println("\n", answer.stop_reason)
close_connection!(connection)
```

The agent process starts in a process group of its own. `close_connection!`
closes its input, and ends the whole group when the process does not end by
itself, so no child of the agent lives on.

## An agent

An agent gives a handler with a method of `answer_request` for each request
that it serves, and serves the client on its standard input and output:

```julia
using AgentClientProtocol
import AgentClientProtocol as ACP

struct EchoAgent <: AgentHandler end

ACP.answer_request(::EchoAgent, request::ACP.InitializeRequest, context) =
    ACP.InitializeResponse(protocol_version = PROTOCOL_VERSION,
                           agent_info = ACP.Implementation(name = "echo", version = "1.0.0"))

ACP.answer_request(::EchoAgent, request::ACP.NewSessionRequest, context) =
    ACP.NewSessionResponse(session_id = string(rand(UInt64); base = 16))

function ACP.answer_request(::EchoAgent, request::ACP.PromptRequest, context)
    for block in request.prompt
        block isa ACP.TextContent || continue
        send_session_update!(context.connection, request.session_id,
                             ACP.AgentMessageChunk(content = ACP.TextContent(text = block.text)))
    end
    ACP.PromptResponse(stop_reason = "end_turn")
end

wait(open_connection(EchoAgent(), stdin, stdout))
```

A request that the handler does not serve gets the error `METHOD_NOT_FOUND`.
Each request runs on a task of its own, so a handler can wait, for example for a
person, while the connection reads on. Notifications run in the order in which
they come.

## The types

The types are generated from the
[schema of the protocol](schema/schema.json), release 1.7.0, by
[`gen/generate.jl`](gen/generate.jl). Each type is a view of one JSON object:

- A property reads a field, with the snake case name of the field.
  `request.session_id` reads `"sessionId"`, and `request.meta` reads `"_meta"`.
  A field with the name of a Julia keyword ends with `_`, as `range.end_`.
- A constructor takes the fields as keywords. An optional field that you do not
  give is not written.
- A field that the type does not know stays in the object, so a message of a
  newer release of the protocol travels on without loss.
- A union is an abstract type, such as `SessionUpdate` or `ContentBlock`, and
  each variant is a type of its own, such as `AgentMessageChunk` or
  `TextContent`. A variant that the schema does not name reads as
  `OtherSessionUpdate`, which keeps the whole object.

`read_json(T, text)` and `write_json(value)` read and write JSON text, and
`convert_from_json(T, value)` and `get_json(object)` convert a plain value. The
types are public, but the module does not export them, because many of their
names are short, such as `Content` and `Range`. Name them with the module, as
the examples do.

## Extension methods

A method whose name starts with `_` is an extension of the protocol. Send one
with plain values:

```julia
send_request!(connection, "_my/method", Dict("key" => "value"))
```

and serve one with a method of `answer_request` that takes the name:

```julia
ACP.answer_request(::MyClient, method::String, params, context) = ...
```

## Cancel a request

`start_request!` sends a request without a wait, `wait_for_answer` waits for
its answer, and `cancel_request!` asks the other side to stop work on it, with
`$/cancel_request`. On the other side, `add_cancel_callback!` and
`is_request_cancelled` tell a handler that its request was withdrawn.

## Update the schema

Put the new `schema.json` in [`schema/`](schema/), change `SCHEMA_RELEASE` in
the generator, and run it:

```
julia --project=. gen/generate.jl
```

Then read the diff of `src/types.jl`.

## Licence

The package is under the MIT licence: see [LICENSE](LICENSE). The schema of
the protocol is under the Apache License 2.0: see [NOTICE](NOTICE).
