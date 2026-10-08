# The generated types: their fields, their unions, and the exact round trip of
# their JSON.

@testset "the types of the protocol" begin
    @testset "a request writes its fields and reads them back" begin
        request = ACP.PromptRequest(session_id = "s1", prompt = [ACP.TextContent(text = "Hello")])
        @test get_json(request) == Dict{String,Any}(
            "sessionId" => "s1", "prompt" => Any[Dict{String,Any}("type" => "text", "text" => "Hello")])
        again = read_json(ACP.PromptRequest, write_json(request))
        @test again == request
        @test again.session_id == "s1"
        @test only(again.prompt) isa ACP.TextContent
        @test only(again.prompt).text == "Hello"
        @test propertynames(again) == (:session_id, :prompt, :meta)
    end

    @testset "a missing required field throws, and names the field" begin
        request = convert_from_json(ACP.PromptRequest, Dict{String,Any}("prompt" => Any[]))
        exception = try
            request.session_id
        catch exception
            exception
        end
        @test exception isa ArgumentError
        @test occursin("`sessionId`", exception.msg)
        @test_throws ArgumentError convert_from_json(Int, "1")
        @test_throws ArgumentError convert_from_json(Int, true)
        @test_throws ArgumentError convert_from_json(String, 1)
    end

    @testset "an optional field is written only when it is given" begin
        chunk = ACP.AgentMessageChunk(content = ACP.TextContent(text = "a"))
        @test !haskey(get_json(chunk), "messageId")
        @test chunk.message_id === nothing
        @test ACP.AgentMessageChunk(content = ACP.TextContent(text = "a"), message_id = "m1").message_id == "m1"
    end

    @testset "a field that is absent reads as the default of the schema" begin
        capabilities = read_json(ACP.AgentCapabilities, "{}")
        @test capabilities.load_session === false
        @test capabilities.prompt_capabilities.image === false
        @test get_json(capabilities) == Dict{String,Any}()
    end

    @testset "`_meta` and unknown fields travel" begin
        text = """{"sessionId":"s1","prompt":[],"_meta":{"a":1},"fromTheFuture":[1,2]}"""
        request = read_json(ACP.PromptRequest, text)
        @test request.meta == Dict{String,Any}("a" => 1)
        @test read_json(write_json(request)) == read_json(text)
        @test read_json(ACP.PromptRequest, """{"sessionId":"s1","prompt":[],"_meta":"bad"}""").meta === nothing
        @test ACP.PromptRequest(session_id = "s", prompt = [], meta = Dict("b" => 2)).meta == Dict{String,Any}("b" => 2)
    end

    @testset "a tag picks the variant of a union" begin
        update(text) = read_json(ACP.SessionNotification, """{"sessionId":"s","update":$(text)}""").update
        @test update("""{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"a"}}""") isa
              ACP.AgentMessageChunk
        @test update("""{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"a"}}""") isa
              ACP.AgentThoughtChunk
        @test update("""{"sessionUpdate":"tool_call","toolCallId":"t","title":"Read"}""") isa ACP.ToolCall
        future = update("""{"sessionUpdate":"from_the_future","x":1}""")
        @test future isa ACP.OtherSessionUpdate
        @test get_json(future) == Dict{String,Any}("sessionUpdate" => "from_the_future", "x" => 1)
        @test convert_from_json(ACP.ContentBlock, Dict("type" => "image", "data" => "", "mimeType" => "image/png")) isa
              ACP.ImageContent
    end

    @testset "an object without a tag is the default variant" begin
        server = convert_from_json(ACP.McpServer, Dict("name" => "tools", "command" => "tool", "args" => [], "env" => []))
        @test server isa ACP.McpServerStdio
        @test server.command == "tool"
        @test convert_from_json(ACP.McpServer, Dict("type" => "http", "name" => "a", "url" => "u", "headers" => [])) isa
              ACP.McpServerHttp
        @test convert_from_json(ACP.AuthMethod, Dict("id" => "login", "name" => "Log in")) isa ACP.AuthMethodAgent
    end

    @testset "a variant gets its tag in a field of its union, and only there" begin
        update = ACP.ToolCallUpdate(tool_call_id = "t1", status = "completed")
        @test !haskey(get_json(update), "sessionUpdate")
        notification = ACP.SessionNotification(session_id = "s", update = update)
        @test get_json(notification)["update"]["sessionUpdate"] == "tool_call_update"
        @test read_json(ACP.SessionNotification, write_json(notification)).update == notification.update
        request = ACP.RequestPermissionRequest(session_id = "s", tool_call = update, options = ACP.PermissionOption[])
        @test !haskey(get_json(request)["toolCall"], "sessionUpdate")
        # A variant that has a type of its own writes its tag itself.
        @test get_json(ACP.AgentMessageChunk(content = ACP.TextContent(text = "a")))["sessionUpdate"] ==
              "agent_message_chunk"
        @test get_json(ACP.RequestPermissionOutcomeCancelled()) == Dict{String,Any}("outcome" => "cancelled")
    end

    @testset "the required fields pick the variant of a structural union" begin
        text = convert_from_json(ACP.EmbeddedResourceResource, Dict("uri" => "file:///a", "text" => "x"))
        blob = convert_from_json(ACP.EmbeddedResourceResource, Dict("uri" => "file:///a", "blob" => "eA=="))
        @test text isa ACP.TextResourceContents
        @test blob isa ACP.BlobResourceContents
        @test convert_from_json(ACP.EmbeddedResourceResource, Dict("uri" => "file:///a")) isa
              ACP.OtherEmbeddedResourceResource
    end

    @testset "a primitive union reads by the kind of the value" begin
        @test convert_from_json(ACP.RequestId, 5) === 5
        @test convert_from_json(ACP.RequestId, "a") == "a"
        @test convert_from_json(ACP.RequestId, nothing) === nothing
        @test convert_from_json(ACP.ElicitationContentValue, Any["a", "b"]) == ["a", "b"]
        @test convert_from_json(ACP.ElicitationContentValue, 1.5) === 1.5
        grouped = convert_from_json(ACP.SessionConfigSelectOptions, Any[Dict("group" => "g", "name" => "G", "options" => [])])
        @test grouped isa Vector{ACP.SessionConfigSelectGroup}
        flat = convert_from_json(ACP.SessionConfigSelectOptions, Any[Dict("value" => "v", "name" => "V")])
        @test flat isa Vector{ACP.SessionConfigSelectOption}
    end

    @testset "a field with the name of a Julia keyword ends with `_`" begin
        range = ACP.Range(start = ACP.Position(line = 1, character = 2), end_ = ACP.Position(line = 3, character = 4))
        @test get_json(range)["end"] == Dict{String,Any}("line" => 3, "character" => 4)
        @test range.end_.line == 3
    end

    @testset "the methods name their types" begin
        @test get_method_name(ACP.PromptRequest) == "session/prompt"
        @test get_response_type(ACP.PromptRequest) == ACP.PromptResponse
        @test get_method_name(ACP.SetSessionConfigOptionRequestValueId) == "session/set_config_option"
        @test get_method_name(ACP.SessionNotification) == "session/update"
        @test ACP.AGENT_METHOD_TYPES["session/prompt"] == ACP.PromptRequest
        @test ACP.CLIENT_METHOD_TYPES["session/request_permission"] == ACP.RequestPermissionRequest
        @test ACP.PROTOCOL_METHOD_TYPES["\$/cancel_request"] == ACP.CancelRequestNotification
        @test ACP.METHOD_NOT_FOUND == -32601
    end

    @testset "an object shows its type and its JSON" begin
        @test repr(ACP.CancelNotification(session_id = "s")) == """CancelNotification({"sessionId":"s"})"""
    end
end
