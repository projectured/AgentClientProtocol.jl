# A client and an agent of this package in one process, connected by two
# streams: requests and notifications both ways, the order of the updates of a
# prompt, a request that the other side withdraws, the errors, and the close.

# A client and an agent, each on one end of two streams.
function open_connection_pair(client_handler, agent_handler)
    to_agent = Base.BufferStream()
    to_client = Base.BufferStream()
    agent = open_connection(agent_handler, to_agent, to_client)
    client = open_connection(client_handler, to_client, to_agent)
    client, agent
end

struct TestAgent <: AgentHandler
    notifications::Channel{Any}
end

TestAgent() = TestAgent(Channel{Any}(16))

ACP.answer_request(::TestAgent, request::ACP.InitializeRequest, context) =
    ACP.InitializeResponse(protocol_version = PROTOCOL_VERSION,
                           agent_info = ACP.Implementation(name = "test-agent", version = "1.0.0"))

ACP.answer_request(::TestAgent, request::ACP.NewSessionRequest, context) =
    ACP.NewSessionResponse(session_id = "session-1")

# The prompt sends a chunk of text, a tool call, and asks the client before it
# answers.
function ACP.answer_request(::TestAgent, request::ACP.PromptRequest, context)
    connection = context.connection
    text = join([block.text for block in request.prompt if block isa ACP.TextContent])
    send_session_update!(connection, request.session_id,
                         ACP.AgentMessageChunk(content = ACP.TextContent(text = "You said: " * text)))
    send_session_update!(connection, request.session_id,
                         ACP.ToolCall(tool_call_id = "t1", title = "Read a file", kind = "read"))
    answer = send_request!(connection, ACP.RequestPermissionRequest(
        session_id = request.session_id, tool_call = ACP.ToolCallUpdate(tool_call_id = "t1"),
        options = [ACP.PermissionOption(option_id = "allow", name = "Allow", kind = "allow_once"),
                   ACP.PermissionOption(option_id = "reject", name = "Reject", kind = "reject_once")]);
        timeout = 10)
    choice = answer.outcome isa ACP.SelectedPermissionOutcome ? answer.outcome.option_id : "cancelled"
    send_session_update!(connection, request.session_id,
                         ACP.ToolCallUpdate(tool_call_id = "t1", status = choice == "allow" ? "completed" : "failed"))
    ACP.PromptResponse(stop_reason = "end_turn")
end

ACP.answer_request(::TestAgent, request::ACP.LoadSessionRequest, context) =
    throw(ProtocolException(ACP.AUTHENTICATION_REQUIRED, "Sign in first.";
                            data = Dict("method" => "claude-login")))

ACP.answer_request(::TestAgent, request::ACP.ResumeSessionRequest, context) =
    error("a secret that must not reach the other side")

ACP.answer_request(::TestAgent, method::String, params, context) =
    method == "_test/echo" ? params : throw(ProtocolException(ACP.METHOD_NOT_FOUND, "No `$(method)` here."))

ACP.receive_notification(agent::TestAgent, notification::ACP.CancelNotification, connection) =
    put!(agent.notifications, notification)

ACP.receive_notification(agent::TestAgent, method::String, params, connection) =
    put!(agent.notifications, method => params)

# A client that records the updates, and answers a permission request with the
# first option, or waits for `person` when `waits` is set.
struct TestClient <: ClientHandler
    updates::Vector{Any}
    person::Channel{Any}
    waits::Bool
    contexts::Channel{RequestContext}
end

TestClient(; waits = false) = TestClient(Any[], Channel{Any}(1), waits, Channel{RequestContext}(1))

ACP.receive_notification(client::TestClient, notification::ACP.SessionNotification, connection) =
    push!(client.updates, notification.update)

function ACP.answer_request(client::TestClient, request::ACP.RequestPermissionRequest, context)
    client.waits || return ACP.RequestPermissionResponse(
        outcome = ACP.SelectedPermissionOutcome(option_id = first(request.options).option_id))
    add_cancel_callback!(() -> put!(client.person, nothing), context)
    put!(client.contexts, context)
    choice = take!(client.person)
    ACP.RequestPermissionResponse(outcome = choice === nothing ? ACP.RequestPermissionOutcomeCancelled() :
                                            ACP.SelectedPermissionOutcome(option_id = choice))
end

@testset "a client and an agent in one process" begin
    @testset "a session and a prompt" begin
        client_handler = TestClient()
        client, agent = open_connection_pair(client_handler, TestAgent())
        initialized = send_request!(client, ACP.InitializeRequest(protocol_version = PROTOCOL_VERSION); timeout = 10)
        @test initialized isa ACP.InitializeResponse
        @test initialized.agent_info.name == "test-agent"
        session = send_request!(client, ACP.NewSessionRequest(cwd = "/work", mcp_servers = []); timeout = 10)
        @test session.session_id == "session-1"
        answer = send_request!(client, ACP.PromptRequest(session_id = session.session_id,
                                                         prompt = [ACP.TextContent(text = "hi")]); timeout = 10)
        @test answer.stop_reason == "end_turn"
        # Each update of the prompt came before its answer, in the order the agent sent them.
        @test [typeof(update) for update in client_handler.updates] ==
              [ACP.AgentMessageChunk, ACP.ToolCall, ACP.ToolCallUpdate]
        @test client_handler.updates[1].content.text == "You said: hi"
        @test client_handler.updates[3].status == "completed"
        close_connection!(client)
        wait(agent)
        @test !is_connection_open(agent)
    end

    @testset "notifications reach the handler, also those of an extension" begin
        agent_handler = TestAgent()
        client, agent = open_connection_pair(TestClient(), agent_handler)
        send_notification!(client, ACP.CancelNotification(session_id = "session-1"))
        @test take!(agent_handler.notifications) == ACP.CancelNotification(session_id = "session-1")
        send_notification!(client, "_test/note", Dict("n" => 1))
        @test take!(agent_handler.notifications) == ("_test/note" => Dict{String,Any}("n" => 1))
        close_connection!(client)
    end

    @testset "an extension method has plain parameters and a plain result" begin
        client, agent = open_connection_pair(TestClient(), TestAgent())
        @test send_request!(client, "_test/echo", Dict("a" => [1, 2]); timeout = 10) ==
              Dict{String,Any}("a" => Any[1, 2])
        exception = try
            send_request!(client, "_test/unknown", Dict(); timeout = 10)
        catch exception
            exception
        end
        @test exception isa ProtocolException && exception.code == ACP.METHOD_NOT_FOUND
        close_connection!(client)
    end

    @testset "an error answer carries its code, its message and its data" begin
        client, agent = open_connection_pair(TestClient(), TestAgent())
        failure(request) = try
            send_request!(client, request; timeout = 10)
            nothing
        catch exception
            exception
        end
        signed_out = failure(ACP.LoadSessionRequest(session_id = "s", cwd = "/", mcp_servers = []))
        @test signed_out isa ProtocolException
        @test (signed_out.code, signed_out.message) == (ACP.AUTHENTICATION_REQUIRED, "Sign in first.")
        @test signed_out.data == Dict{String,Any}("method" => "claude-login")
        # Another exception of a handler answers an internal error that does not
        # quote it. The tasks of a connection log with the logger of the task that
        # opened it, so this connection opens in the scope of the test of the log.
        internal = @test_logs (:warn, r"failed to answer") match_mode = :any begin
            logged_client, logged_agent = open_connection_pair(TestClient(), TestAgent())
            exception = try
                send_request!(logged_client, ACP.ResumeSessionRequest(session_id = "s", cwd = "/"); timeout = 10)
            catch exception
                exception
            end
            close_connection!(logged_client)
            exception
        end
        @test internal.code == ACP.INTERNAL_ERROR
        @test !occursin("secret", internal.message)
        # A request that the handler does not serve, also without its required fields.
        @test failure(ACP.ListSessionsRequest()).code == ACP.METHOD_NOT_FOUND
        unserved = try
            send_request!(client, "session/set_mode", Dict(); timeout = 10)
        catch exception
            exception
        end
        @test unserved.code == ACP.METHOD_NOT_FOUND
        # A request without a required field.
        invalid = try
            send_request!(client, "session/prompt", Dict("sessionId" => "s"); timeout = 10)
        catch exception
            exception
        end
        @test invalid.code == ACP.INVALID_PARAMS
        @test occursin("`prompt`", invalid.message)
        close_connection!(client)
    end

    @testset "the other side withdraws a request with `\$/cancel_request`" begin
        client_handler = TestClient(waits = true)
        client, agent = open_connection_pair(client_handler, TestAgent())
        request = start_request!(agent, ACP.RequestPermissionRequest(
            session_id = "s", tool_call = ACP.ToolCallUpdate(tool_call_id = "t"),
            options = [ACP.PermissionOption(option_id = "allow", name = "Allow", kind = "allow_once")]))
        context = take!(client_handler.contexts)
        @test !is_request_cancelled(context)
        cancel_request!(request)
        answer = wait_for_answer(request; timeout = 10)
        @test answer.outcome isa ACP.RequestPermissionOutcomeCancelled
        @test is_request_cancelled(context)
        # A callback added after the cancel runs at once.
        ran = Ref(false)
        add_cancel_callback!(() -> ran[] = true, context)
        @test ran[]
        close_connection!(client)
    end

    @testset "a person answers a request that waits" begin
        client_handler = TestClient(waits = true)
        client, agent = open_connection_pair(client_handler, TestAgent())
        request = start_request!(agent, ACP.RequestPermissionRequest(
            session_id = "s", tool_call = ACP.ToolCallUpdate(tool_call_id = "t"),
            options = [ACP.PermissionOption(option_id = "allow", name = "Allow", kind = "allow_once")]))
        take!(client_handler.contexts)
        @test_throws ErrorException wait_for_answer(request; timeout = 0.2)
        close_connection!(client)
        close_connection!(agent)
    end

    @testset "the close of the other side fails the requests that wait" begin
        client_handler = TestClient(waits = true)
        client, agent = open_connection_pair(client_handler, TestAgent())
        request = start_request!(agent, ACP.RequestPermissionRequest(
            session_id = "s", tool_call = ACP.ToolCallUpdate(tool_call_id = "t"),
            options = ACP.PermissionOption[]))
        context = take!(client_handler.contexts)
        close_connection!(client)
        @test_throws ProtocolException wait_for_answer(request; timeout = 10)
        @test_throws ProtocolException send_request!(client, ACP.InitializeRequest(protocol_version = 1))
        put!(client_handler.person, nothing)
    end

    @testset "a line that is not JSON is dropped, and the next message comes" begin
        @test_logs (:warn, r"not JSON") match_mode = :any begin
            to_agent = Base.BufferStream()
            to_client = Base.BufferStream()
            client = open_connection(TestClient(), to_client, to_agent)
            agent = open_connection(TestAgent(), to_agent, to_client)
            write(to_agent, "this is not JSON\n")
            @test send_request!(client, "_test/echo", Dict("b" => 1); timeout = 10) == Dict{String,Any}("b" => 1)
            close_connection!(client)
        end
    end
end
