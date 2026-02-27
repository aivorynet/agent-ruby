# frozen_string_literal: true

require "socket"
require "openssl"
require "json"
require "securerandom"
require "base64"
require "uri"

module AIVoryMonitor
  # WebSocket connection to the AIVory backend.
  class BackendConnection
    attr_reader :connected, :authenticated

    def initialize(config)
      @config = config
      @socket = nil
      @ssl_socket = nil
      @connected = false
      @authenticated = false
      @reconnect_attempts = 0
      @agent_id = generate_agent_id
      @message_queue = []
      @event_handlers = {}
      @mutex = Mutex.new
      @heartbeat_thread = nil
    end

    # Connects to the backend.
    def connect
      return if @connected

      begin
        uri = URI.parse(@config.backend_url)
        host = uri.host || "api.aivory.net"
        port = uri.port || (uri.scheme == "wss" ? 443 : 80)
        path = uri.path.empty? ? "/monitor/agent" : uri.path

        # Create TCP socket
        @socket = TCPSocket.new(host, port)

        # Wrap with SSL if wss
        if uri.scheme == "wss"
          ssl_context = OpenSSL::SSL::SSLContext.new
          ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
          @ssl_socket = OpenSSL::SSL::SSLSocket.new(@socket, ssl_context)
          @ssl_socket.hostname = host
          @ssl_socket.connect
        end

        # Perform WebSocket handshake
        ws_key = Base64.strict_encode64(SecureRandom.random_bytes(16))
        handshake = [
          "GET #{path} HTTP/1.1",
          "Host: #{host}",
          "Upgrade: websocket",
          "Connection: Upgrade",
          "Sec-WebSocket-Key: #{ws_key}",
          "Sec-WebSocket-Version: 13",
          "Authorization: Bearer #{@config.api_key}"
        ].join("\r\n") + "\r\n\r\n"

        active_socket.write(handshake)

        response = active_socket.gets("\r\n\r\n")
        unless response&.include?("101")
          puts "[AIVory Monitor] WebSocket handshake failed" if @config.debug
          close_sockets
          schedule_reconnect
          return false
        end

        @connected = true
        @reconnect_attempts = 0

        puts "[AIVory Monitor] WebSocket connected" if @config.debug

        authenticate

        # Start heartbeat thread
        start_heartbeat

        # Start message receiver thread
        start_receiver

        true
      rescue StandardError => e
        puts "[AIVory Monitor] Connection error: #{e.message}" if @config.debug
        close_sockets
        schedule_reconnect
        false
      end
    end

    # Disconnects from the backend.
    def disconnect
      @mutex.synchronize do
        stop_heartbeat
        close_sockets
        @connected = false
        @authenticated = false
      end

      puts "[AIVory Monitor] Disconnected" if @config.debug
    end

    # Sends an exception to the backend.
    def send_exception(data)
      payload = data.to_h
      payload[:agent_id] = @agent_id
      payload[:environment] = @config.environment
      payload[:hostname] = Socket.gethostname

      send_message("exception", payload)
    end

    # Sends a snapshot to the backend.
    def send_snapshot(data)
      payload = data.to_h
      payload[:agent_id] = @agent_id

      send_message("snapshot", payload)
    end

    # Sends a breakpoint hit to the backend.
    def send_breakpoint_hit(breakpoint_id, payload)
      payload[:breakpoint_id] = breakpoint_id
      payload[:agent_id] = @agent_id

      send_message("breakpoint_hit", payload)
    end

    # Registers a callback for breakpoint commands from the backend.
    def set_breakpoint_callback(&block)
      @breakpoint_callback = block
    end

    # Registers an event handler.
    def on(event, &block)
      @event_handlers[event.to_s] = block
    end

    # Checks if connected and authenticated.
    def connected?
      @connected && @authenticated
    end

    private

    def active_socket
      @ssl_socket || @socket
    end

    def close_sockets
      @ssl_socket&.close rescue nil
      @socket&.close rescue nil
      @ssl_socket = nil
      @socket = nil
    end

    def send_message(type, payload)
      message = {
        type: type,
        payload: payload,
        timestamp: (Time.now.to_f * 1000).to_i
      }

      json = JSON.generate(message)

      @mutex.synchronize do
        if @connected && @authenticated
          send_websocket_frame(json)
        else
          @message_queue << json
          @message_queue.shift if @message_queue.size > 100
        end
      end
    end

    def authenticate
      payload = {
        api_key: @config.api_key,
        agent_id: @agent_id,
        hostname: Socket.gethostname,
        environment: @config.environment,
        runtime: "ruby",
        runtime_version: RUBY_VERSION,
        agent_version: VERSION
      }

      payload[:application_name] = @config.application_name if @config.application_name

      message = {
        type: "register",
        payload: payload,
        timestamp: (Time.now.to_f * 1000).to_i
      }

      send_websocket_frame(JSON.generate(message))
    end

    def start_heartbeat
      @heartbeat_thread = Thread.new do
        loop do
          sleep(@config.heartbeat_interval_ms / 1000.0)
          break unless @connected

          send_message("heartbeat", {
            timestamp: (Time.now.to_f * 1000).to_i,
            agent_id: @agent_id,
            metrics: {
              memory_mb: get_memory_usage
            }
          })
        end
      end
    end

    def stop_heartbeat
      @heartbeat_thread&.kill
      @heartbeat_thread = nil
    end

    def start_receiver
      Thread.new do
        loop do
          break unless @connected

          begin
            frame = read_websocket_frame
            handle_message(frame) if frame
          rescue StandardError => e
            puts "[AIVory Monitor] Receive error: #{e.message}" if @config.debug
            break
          end
        end

        handle_disconnect
      end
    end

    def handle_message(data)
      message = JSON.parse(data)
      type = message["type"]

      puts "[AIVory Monitor] Received: #{type}" if @config.debug

      case type
      when "registered"
        handle_registered(message["payload"])
      when "error"
        handle_error(message["payload"])
      when "set_breakpoint"
        @breakpoint_callback&.call("set", message["payload"])
        emit("set_breakpoint", message["payload"])
      when "remove_breakpoint"
        @breakpoint_callback&.call("remove", message["payload"])
        emit("remove_breakpoint", message["payload"])
      end
    rescue JSON::ParserError => e
      puts "[AIVory Monitor] JSON parse error: #{e.message}" if @config.debug
    end

    def handle_registered(payload)
      @authenticated = true
      @agent_id = payload["agent_id"] if payload["agent_id"]

      # Flush queued messages
      @mutex.synchronize do
        @message_queue.each { |msg| send_websocket_frame(msg) }
        @message_queue.clear
      end

      puts "[AIVory Monitor] Agent registered" if @config.debug
    end

    def handle_error(payload)
      code = payload["code"] || "unknown"
      message = payload["message"] || "Unknown error"

      warn "[AIVory Monitor] Backend error: #{code} - #{message}"

      if %w[auth_error invalid_api_key].include?(code)
        warn "[AIVory Monitor] Authentication failed, disabling reconnect"
        @config.max_reconnect_attempts = 0
        disconnect
      end
    end

    def handle_disconnect
      @connected = false
      @authenticated = false
      schedule_reconnect
    end

    def emit(event, data)
      handler = @event_handlers[event]
      handler&.call(data)
    end

    def schedule_reconnect
      return if @reconnect_attempts >= @config.max_reconnect_attempts

      @reconnect_attempts += 1
      delay = [1 * (2**(@reconnect_attempts - 1)), 60].min

      puts "[AIVory Monitor] Reconnecting in #{delay}s (attempt #{@reconnect_attempts})" if @config.debug

      Thread.new do
        sleep(delay)
        connect
      end
    end

    def generate_agent_id
      "#{Socket.gethostname}-#{SecureRandom.hex(4)}-#{Process.pid}"
    end

    def get_memory_usage
      if File.exist?("/proc/self/statm")
        (File.read("/proc/self/statm").split[1].to_i * 4096) / (1024.0 * 1024.0)
      else
        0
      end
    rescue StandardError
      0
    end

    def send_websocket_frame(payload)
      length = payload.bytesize
      frame = [0x81].pack("C") # Text frame, FIN bit set

      if length <= 125
        frame += [(length | 0x80)].pack("C")
      elsif length <= 65_535
        frame += [126 | 0x80, length].pack("Cn")
      else
        frame += [127 | 0x80, length].pack("CQ>")
      end

      # Generate and apply mask
      mask = SecureRandom.random_bytes(4)
      frame += mask

      masked_payload = payload.bytes.map.with_index { |b, i| b ^ mask.bytes[i % 4] }.pack("C*")
      frame += masked_payload

      active_socket.write(frame)
    rescue StandardError => e
      puts "[AIVory Monitor] Send error: #{e.message}" if @config.debug
    end

    def read_websocket_frame
      header = active_socket.read(2)
      return nil unless header && header.length == 2

      byte1, byte2 = header.unpack("CC")
      masked = (byte2 & 0x80) != 0
      length = byte2 & 0x7f

      if length == 126
        length = active_socket.read(2).unpack1("n")
      elsif length == 127
        length = active_socket.read(8).unpack1("Q>")
      end

      if masked
        mask = active_socket.read(4)
        payload = active_socket.read(length)
        payload.bytes.map.with_index { |b, i| b ^ mask.bytes[i % 4] }.pack("C*")
      else
        active_socket.read(length)
      end
    rescue StandardError
      nil
    end
  end
end
