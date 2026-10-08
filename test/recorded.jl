# The messages that the agent `claude-agent-acp` 0.87.0 and a client exchanged,
# with no account data: each one reads as its type, every field of it reads, and
# it writes back the same JSON.

const RECORDED_PATH = joinpath(@__DIR__, "recorded", "claude-agent-acp-0.87.0.jsonl")

# Read every property of a value, and of each value that it holds.
read_all_properties(value) = nothing
read_all_properties(value::AbstractVector) = foreach(read_all_properties, value)
read_all_properties(value::AbstractDict) = foreach(read_all_properties, values(value))
function read_all_properties(object::ProtocolObject)
    for name in propertynames(object)
        read_all_properties(getproperty(object, name))
    end
end

# The type of a recorded message: the request or notification of its method, or
# the response of the method of the request that it answers.
function get_recorded_type(record)
    kind = record["kind"]
    startswith(kind, "answer:") && return get_response_type(ACP.AGENT_METHOD_TYPES[kind[8:end]])
    method = record["message"]["method"]
    record["from"] == "client" ? ACP.AGENT_METHOD_TYPES[method] : ACP.CLIENT_METHOD_TYPES[method]
end

@testset "the recorded messages of claude-agent-acp 0.87.0" begin
    records = [read_json(line) for line in eachline(RECORDED_PATH)]
    values = Dict{String,Any}()
    @testset "each message reads, and writes back the same JSON: $(record["kind"])" for record in records
        message = record["message"]
        json = startswith(record["kind"], "answer:") ? message["result"] : message["params"]
        value = convert_from_json(get_recorded_type(record), json)
        read_all_properties(value)
        @test read_json(write_json(value)) == json
        values[record["kind"]] = value
    end

    @testset "the values of the messages" begin
        initialized = values["answer:initialize"]
        @test initialized.agent_info.title == "Claude Agent"
        @test initialized.agent_capabilities.load_session
        @test initialized.agent_capabilities.prompt_capabilities.image
        @test initialized.agent_capabilities.session_capabilities.close !== nothing
        login = only(initialized.auth_methods)
        @test login isa ACP.AuthMethodTerminal
        @test login.args == ["--cli"]

        session = values["answer:session/new"]
        @test session.modes.current_mode_id == "default"
        @test all(option -> option isa ACP.SessionConfigOptionSelect, session.config_options)
        @test [option.category for option in session.config_options] ==
              ["mode", "model", "thought_level", "model_config", nothing]
        effort = session.config_options[3]
        @test effort.current_value == "xhigh"
        @test effort.options isa Vector{ACP.SessionConfigSelectOption}
        @test "max" in [option.value for option in effort.options]

        commands = values["session/update/available_commands_update"].update
        @test commands isa ACP.AvailableCommandsUpdate
        @test [command.name for command in commands.available_commands] == ["compact", "effort", "init"]
        @test commands.available_commands[1].input isa ACP.UnstructuredCommandInput
        @test commands.available_commands[3].input === nothing

        usage = values["session/update/usage_update"].update
        @test (usage.used, usage.size) == (36012, 1000000)
        @test usage.meta["_claude/model"] == "claude-opus-5-5"

        @test values["session/update/agent_message_chunk"].update.content.text == "OK"
        @test values["session/update/agent_thought_chunk"].update isa ACP.AgentThoughtChunk
        @test values["session/update/session_info_update"].update.title == "Reply with OK"

        answer = values["answer:session/prompt"]
        @test answer.stop_reason == "end_turn"
        @test answer.usage.total_tokens == 36013
        @test values["answer:session/close"] isa ACP.CloseSessionResponse
    end
end
