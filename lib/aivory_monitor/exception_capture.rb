# frozen_string_literal: true

require "digest"

module AIVoryMonitor
  # Captures exceptions and their context.
  class ExceptionCapture
    def initialize(config, connection)
      @config = config
      @connection = connection
      @captured_fingerprints = {}
      @original_at_exit = nil
      @installed = false
    end

    # Installs exception handlers.
    def install
      return if @installed

      # Install global exception handler via TracePoint
      @trace_point = TracePoint.new(:raise) do |tp|
        handle_raise(tp)
      end
      @trace_point.enable

      @installed = true
      puts "[AIVory Monitor] Exception handlers installed" if @config.debug
    end

    # Uninstalls exception handlers.
    def uninstall
      return unless @installed

      @trace_point&.disable
      @trace_point = nil

      @installed = false
      puts "[AIVory Monitor] Exception handlers uninstalled" if @config.debug
    end

    # Manually captures an exception.
    #
    # @param exception [Exception] The exception to capture
    # @param context [Hash, nil] Additional context
    def capture(exception, context = nil)
      capture_exception(exception, "error", context)
    end

    private

    def handle_raise(trace_point)
      exception = trace_point.raised_exception

      # Skip internal exceptions
      return if exception.is_a?(SystemExit)
      return if exception.is_a?(SignalException)

      # Apply sampling
      if @config.sampling_rate < 1.0 && rand > @config.sampling_rate
        return
      end

      capture_exception(exception, "error")
    rescue StandardError => e
      puts "[AIVory Monitor] Error in raise handler: #{e.message}" if @config.debug
    end

    def capture_exception(exception, severity, context = nil)
      # Compute fingerprint for deduplication
      fingerprint = compute_fingerprint(exception)

      # Skip if already captured
      return if @captured_fingerprints[fingerprint]

      @captured_fingerprints[fingerprint] = true

      # Keep set from growing too large
      @captured_fingerprints.clear if @captured_fingerprints.size > 1000

      data = build_exception_data(exception, severity, context)
      @connection.send_exception(data)

      puts "[AIVory Monitor] Captured exception: #{exception.class}" if @config.debug
    rescue StandardError => e
      puts "[AIVory Monitor] Error capturing exception: #{e.message}" if @config.debug
    end

    def build_exception_data(exception, severity, context)
      data = ExceptionData.new
      data.exception_type = exception.class.name
      data.message = exception.message
      data.severity = severity
      data.fingerprint = compute_fingerprint(exception)
      data.stack_trace = build_stack_frames(exception.backtrace || [])
      data.request_context = context || build_request_context

      # Capture exception properties as local variables
      data.local_variables = capture_exception_as_variables(exception)

      # Extract file/line from first backtrace entry
      if exception.backtrace&.first
        match = exception.backtrace.first.match(/^(.+):(\d+)/)
        if match
          data.file_path = match[1]
          data.line_number = match[2].to_i
        end
      end

      # Extract class/method from first frame
      unless data.stack_trace.empty?
        first_frame = data.stack_trace.first
        data.class_name = first_frame.class_name
        data.method_name = first_frame.method_name
      end

      data
    end

    # Captures exception properties as local variables.
    def capture_exception_as_variables(exception, depth = 0)
      return {} if depth > @config.max_variable_depth

      variables = {}

      # Capture message
      msg = exception.message
      msg_var = VariableData.new
      msg_var.name = "message"
      msg_var.type = "String"
      if msg.length > 500
        msg_var.value = msg[0, 500]
        msg_var.is_truncated = true
      else
        msg_var.value = msg
      end
      variables["message"] = msg_var

      # Capture backtrace location
      if exception.backtrace&.first
        bt_var = VariableData.new
        bt_var.name = "location"
        bt_var.type = "String"
        bt_var.value = exception.backtrace.first
        variables["location"] = bt_var
      end

      # Capture exception cause (Ruby 2.1+)
      if exception.respond_to?(:cause) && exception.cause
        cause = exception.cause
        cause_var = VariableData.new
        cause_var.name = "cause"
        cause_var.type = cause.class.name
        cause_msg = cause.message
        if cause_msg.length > 200
          cause_var.value = cause_msg[0, 200]
          cause_var.is_truncated = true
        else
          cause_var.value = cause_msg
        end
        cause_var.children = capture_exception_as_variables(cause, depth + 1)
        variables["cause"] = cause_var
      end

      # Capture custom exception instance variables
      exception.instance_variables.each do |ivar|
        next if %i[@message @backtrace @cause @__id__ @__send__].include?(ivar)

        begin
          value = exception.instance_variable_get(ivar)
          var_name = "prop:#{ivar.to_s.sub(/^@/, '')}"
          variables[var_name] = capture_variable(ivar.to_s, value, depth + 1)
        rescue StandardError
          # Skip if can't access
        end
      end

      # For common exception types, capture specific properties
      capture_specific_exception_properties(exception, variables, depth)

      # Capture Rack/Rails request context if available
      capture_web_context(variables, depth)

      variables
    end

    def capture_specific_exception_properties(exception, variables, depth)
      # SystemCallError (Errno::*)
      if exception.is_a?(SystemCallError)
        errno_var = VariableData.new
        errno_var.name = "errno"
        errno_var.type = "Integer"
        errno_var.value = exception.errno.to_s
        variables["errno"] = errno_var
      end

      # ArgumentError with detailed message
      if exception.is_a?(ArgumentError) && exception.message.include?("wrong number of arguments")
        arg_var = VariableData.new
        arg_var.name = "argument_error"
        arg_var.type = "String"
        arg_var.value = exception.message
        variables["argument_error"] = arg_var
      end

      # NameError/NoMethodError
      if exception.is_a?(NameError)
        name_var = VariableData.new
        name_var.name = "name"
        name_var.type = "Symbol"
        name_var.value = exception.name.to_s
        variables["name"] = name_var

        if exception.respond_to?(:receiver)
          begin
            receiver_var = VariableData.new
            receiver_var.name = "receiver"
            receiver_var.type = exception.receiver.class.name
            receiver_var.value = exception.receiver.class.name
            variables["receiver"] = receiver_var
          rescue StandardError
            # Skip if receiver can't be accessed
          end
        end
      end

      # LoadError
      if exception.is_a?(LoadError) && exception.respond_to?(:path)
        path_var = VariableData.new
        path_var.name = "path"
        path_var.type = "String"
        path_var.value = exception.path.to_s
        variables["path"] = path_var
      end
    end

    def capture_web_context(variables, depth)
      # Rack environment
      if defined?(Rack) && (env = Thread.current[:rack_env])
        rack_vars = {}

        if env["REQUEST_METHOD"]
          method_var = VariableData.new
          method_var.name = "REQUEST_METHOD"
          method_var.type = "String"
          method_var.value = env["REQUEST_METHOD"]
          rack_vars["REQUEST_METHOD"] = method_var
        end

        if env["PATH_INFO"]
          path_var = VariableData.new
          path_var.name = "PATH_INFO"
          path_var.type = "String"
          path_var.value = env["PATH_INFO"]
          rack_vars["PATH_INFO"] = path_var
        end

        if env["QUERY_STRING"] && !env["QUERY_STRING"].empty?
          qs_var = VariableData.new
          qs_var.name = "QUERY_STRING"
          qs_var.type = "String"
          qs = env["QUERY_STRING"]
          if qs.length > 500
            qs_var.value = qs[0, 500]
            qs_var.is_truncated = true
          else
            qs_var.value = qs
          end
          rack_vars["QUERY_STRING"] = qs_var
        end

        unless rack_vars.empty?
          rack_root = VariableData.new
          rack_root.name = "rack_env"
          rack_root.type = "Hash"
          rack_root.value = "Hash(#{rack_vars.size})"
          rack_root.children = rack_vars
          variables["rack_env"] = rack_root
        end
      end

      # Rails params
      if defined?(Rails) && defined?(ActionController::Base)
        begin
          controller = Thread.current[:current_controller]
          if controller && controller.respond_to?(:params)
            params = controller.params.to_unsafe_h
            sanitized = sanitize_params(params)

            if sanitized.any?
              params_var = VariableData.new
              params_var.name = "params"
              params_var.type = "Hash"
              params_var.value = "Hash(#{sanitized.size})"
              params_var.children = sanitized.transform_values { |v| capture_variable(v.class.name, v, depth + 1) }
              variables["params"] = params_var
            end
          end
        rescue StandardError
          # Ignore errors accessing params
        end
      end
    end

    def sanitize_params(params, depth = 0)
      return {} if depth > 3

      sensitive_keys = %w[password passwd secret token api_key apikey auth authorization
                          credit_card creditcard cvv ssn private_key privatekey]

      params.each_with_object({}) do |(key, value), result|
        key_str = key.to_s.downcase
        is_sensitive = sensitive_keys.any? { |sk| key_str.include?(sk) }

        if is_sensitive
          result[key.to_s] = "[REDACTED]"
        elsif value.is_a?(Hash)
          result[key.to_s] = sanitize_params(value, depth + 1)
        elsif value.is_a?(Array)
          result[key.to_s] = value.map { |v| v.is_a?(Hash) ? sanitize_params(v, depth + 1) : v }
        else
          result[key.to_s] = value
        end
      end
    end

    def build_stack_frames(backtrace)
      backtrace.map do |line|
        frame = StackFrameData.new

        # Parse backtrace line: "/path/to/file.rb:123:in `method_name'"
        if (match = line.match(/^(.+):(\d+):in `(.+)'$/))
          frame.file_path = match[1]
          frame.file_name = File.basename(match[1])
          frame.line_number = match[2].to_i
          full_method = match[3]

          # Try to extract class and method
          if full_method.include?("#")
            parts = full_method.split("#")
            frame.class_name = parts[0]
            frame.method_name = parts[1]
          elsif full_method.include?(".")
            parts = full_method.split(".")
            frame.class_name = parts[0]
            frame.method_name = parts[1]
          else
            frame.method_name = full_method
          end

          frame.is_native = frame.file_path.start_with?("<") || frame.file_path.include?("/gems/")
        elsif (match = line.match(/^(.+):(\d+)$/))
          frame.file_path = match[1]
          frame.file_name = File.basename(match[1])
          frame.line_number = match[2].to_i
          frame.is_native = frame.file_path.start_with?("<")
        else
          frame.file_path = line
          frame.is_native = true
        end

        # Capture local variables if depth allows
        if @config.max_variable_depth.positive?
          frame.local_variables = capture_binding_variables(frame.file_path, frame.line_number)
        end

        frame
      end
    end

    def capture_binding_variables(file_path, line_number)
      # Note: Ruby doesn't easily expose local variables from arbitrary stack frames
      # This would require using binding_of_caller or similar gems
      nil
    end

    def capture_variable(name, value, depth)
      var = VariableData.new
      var.name = name.to_s
      var.type = value.class.name

      if value.nil?
        var.is_null = true
        var.value = "nil"
      elsif value.is_a?(Numeric) || value.is_a?(TrueClass) || value.is_a?(FalseClass)
        var.value = value.to_s
      elsif value.is_a?(String)
        if value.length > 200
          var.value = value[0, 200] + "..."
          var.is_truncated = true
        else
          var.value = value
        end
      elsif value.is_a?(Symbol)
        var.value = ":#{value}"
      elsif value.is_a?(Array)
        var.value = "Array(#{value.size})"
        if depth < @config.max_variable_depth && value.size <= 10
          var.children = value.each_with_index.to_h do |v, i|
            ["[#{i}]", capture_variable("[#{i}]", v, depth + 1)]
          end
        end
      elsif value.is_a?(Hash)
        var.value = "Hash(#{value.size})"
        if depth < @config.max_variable_depth && value.size <= 10
          var.children = value.transform_keys(&:to_s).transform_values do |v|
            capture_variable(v.class.name, v, depth + 1)
          end
        end
      else
        var.value = value.class.name
      end

      var
    end

    def build_request_context
      context = {}

      # Rails request context
      if defined?(Rails) && defined?(ActionController::Base)
        begin
          controller = Thread.current[:current_controller]
          if controller
            request = controller.request
            context[:http_method] = request.method
            context[:http_path] = request.path
            context[:http_host] = request.host
            context[:user_agent] = request.user_agent
            context[:remote_ip] = request.remote_ip
            context[:request_id] = request.request_id
          end
        rescue StandardError
          # Ignore errors accessing request
        end
      end

      # Rack request context
      if defined?(Rack) && (env = Thread.current[:rack_env])
        context[:http_method] ||= env["REQUEST_METHOD"]
        context[:http_path] ||= env["PATH_INFO"]
        context[:http_host] ||= env["HTTP_HOST"]
        context[:user_agent] ||= env["HTTP_USER_AGENT"]
        context[:remote_ip] ||= env["REMOTE_ADDR"]
      end

      context
    end

    def compute_fingerprint(exception)
      backtrace = exception.backtrace || []
      top_frames = backtrace.first(3)

      parts = [exception.class.name]
      top_frames.each do |frame|
        # Normalize the frame to just file:line:method
        if (match = frame.match(/^(.+):(\d+):in `(.+)'$/))
          parts << "#{match[1]}:#{match[2]}:#{match[3]}"
        else
          parts << frame
        end
      end

      Digest::SHA256.hexdigest(parts.join(":"))
    end
  end
end
