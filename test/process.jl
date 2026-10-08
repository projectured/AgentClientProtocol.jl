# The other side as a process: a shell script that answers `initialize`, and then
# ends with its input, stays with a child of its own, or ends and leaves that
# child with its output open.

const ANSWER_SCRIPT = raw"""
read -r line
id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id"
echo "a line of the log" >&2
case "$MODE" in
    ends) cat > /dev/null ;;
    stays) sleep 3600 & echo $! > "$PID_FILE"; wait ;;
    leaves) sleep 3600 & echo $! > "$PID_FILE"; exit 0 ;;
esac
"""

struct ProcessClient <: ClientHandler end

is_process_alive(pid::Integer) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0

function open_script_connection(mode, pid_file; log_line = line -> nothing)
    command = addenv(`sh -c $(ANSWER_SCRIPT)`, "MODE" => mode, "PID_FILE" => pid_file)
    open_connection(ProcessClient(), command; log_line)
end

@testset "the other side as a process" begin
    mktempdir() do directory
        pid_file = joinpath(directory, "child.pid")

        @testset "a process answers, logs, and ends with its input" begin
            lines = Channel{String}(8)
            connection = open_script_connection("ends", pid_file; log_line = line -> put!(lines, line))
            answer = send_request!(connection, ACP.InitializeRequest(protocol_version = PROTOCOL_VERSION);
                                   timeout = 30)
            @test answer.protocol_version == 1
            @test take!(lines) == "a line of the log"
            process = connection.process
            started = time()
            close_connection!(connection)
            @test process_exited(process)
            @test time() - started < 4
        end

        @testset "a process that stays ends with its children" begin
            connection = open_script_connection("stays", pid_file)
            send_request!(connection, ACP.InitializeRequest(protocol_version = PROTOCOL_VERSION); timeout = 30)
            @test timedwait(() -> isfile(pid_file) && !isempty(read(pid_file, String)), 30.0) === :ok
            child = parse(Int, read(pid_file, String))
            @test is_process_alive(child)
            close_connection!(connection)
            @test process_exited(connection.process)
            @test timedwait(() -> !is_process_alive(child), 5.0) === :ok
            rm(pid_file)
        end

        @testset "the end of the process closes the connection, and ends its children" begin
            connection = open_script_connection("leaves", pid_file)
            send_request!(connection, ACP.InitializeRequest(protocol_version = PROTOCOL_VERSION); timeout = 30)
            @test timedwait(() -> process_exited(connection.process), 30.0) === :ok
            @test timedwait(() -> !is_connection_open(connection), 10.0) === :ok
            child = parse(Int, read(pid_file, String))
            @test timedwait(() -> !is_process_alive(child), 10.0) === :ok
            @test_throws ProtocolException send_request!(connection, ACP.InitializeRequest(protocol_version = 1))
        end
    end
end
