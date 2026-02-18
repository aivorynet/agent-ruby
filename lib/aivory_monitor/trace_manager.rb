# frozen_string_literal: true

module AIVoryMonitor
  # Represents a single breakpoint.
  class BreakpointInfo
    attr_accessor :backend_id, :file_path, :line_number, :condition, :max_hits, :hit_count, :normalized_path

    def initialize(backend_id, file_path, line_number, condition = nil, max_hits = 1)
      @backend_id = backend_id
      @file_path = file_path
      @line_number = line_number
      @condition = condition
      @max_hits = [[max_hits, 1].max, 50].min
      @hit_count = 0
      @normalized_path = File.expand_path(file_path).downcase
    rescue StandardError
      @normalized_path = file_path.downcase
    end
  end

  # Manages tracing for breakpoint support using TracePoint.
  class TraceManager
    MAX_CAPTURES_PER_SECOND = 50

    def initialize(config, connection)
      @config = config
      @connection = connection
      @enabled = false
      @breakpoints = {}
      @breakpoints_by_file = {}
      @trace_point = nil
      @capture_count = 0
      @capture_window_start = Time.now

      connection.set_breakpoint_callback { |cmd, payload| handle_command(cmd, payload) }
    end

    def enable
      return if @enabled

      @trace_point = TracePoint.new(:line) do |tp|
        trace_callback(tp)
      end
      @trace_point.enable

      @enabled = true
      puts "[AIVory Monitor] Trace manager enabled" if @config.debug
    end

    def disable
      return unless @enabled

      @trace_point&.disable
      @trace_point = nil
      @breakpoints.clear
      @breakpoints_by_file.clear

      @enabled = false
      puts "[AIVory Monitor] Trace manager disabled" if @config.debug
    end

    def set_breakpoint(backend_id, file_path, line_number, condition = nil, max_hits = 1)
      bp = BreakpointInfo.new(backend_id, file_path, line_number, condition, max_hits)
      @breakpoints[backend_id] = bp

      @breakpoints_by_file[bp.normalized_path] ||= []
      @breakpoints_by_file[bp.normalized_path] << bp

      puts "[AIVory Monitor] Breakpoint set: #{backend_id} at #{file_path}:#{line_number}" if @config.debug
    end

    def remove_breakpoint(backend_id)
      bp = @breakpoints.delete(backend_id)
      return unless bp

      file_bps = @breakpoints_by_file[bp.normalized_path]
      if file_bps
        file_bps.reject! { |b| b.backend_id == backend_id }
        @breakpoints_by_file.delete(bp.normalized_path) if file_bps.empty?
      end

      puts "[AIVory Monitor] Breakpoint removed: #{backend_id}" if @config.debug
    end

    private

    def handle_command(command, payload)
      case command
      when "set"
        set_breakpoint(
          payload["id"] || "",
          payload["file_path"] || payload["file"] || "",
          (payload["line_number"] || payload["line"] || 0).to_i,
          payload["condition"],
          (payload["max_hits"] || 1).to_i
        )
      when "remove"
        remove_breakpoint(payload["id"] || "")
      end
    end

    def trace_callback(tp)
      return if @breakpoints_by_file.empty?

      file_path = tp.path
      return unless file_path

      normalized = begin
        File.expand_path(file_path).downcase
      rescue StandardError
        file_path.downcase
      end

      # Look up breakpoints for this file (exact match, then suffix match)
      file_bps = @breakpoints_by_file[normalized]
      unless file_bps
        @breakpoints_by_file.each do |bp_path, bps|
          if normalized.end_with?(bp_path) || bp_path.end_with?(normalized)
            file_bps = bps
            break
          end
        end
      end
      return unless file_bps

      line = tp.lineno
      file_bps.each do |bp|
        handle_hit(bp, tp) if bp.line_number == line
      end
    end

    def handle_hit(bp, tp)
      return if bp.hit_count >= bp.max_hits
      return unless rate_limit_ok?

      # Evaluate condition if present
      if bp.condition && !bp.condition.empty?
        begin
          result = tp.binding.eval(bp.condition)
          return unless result
        rescue StandardError => e
          puts "[AIVory Monitor] Condition eval error: #{e.message}" if @config.debug
          return
        end
      end

      bp.hit_count += 1

      puts "[AIVory Monitor] Breakpoint hit: #{bp.backend_id}" if @config.debug

      local_variables = capture_locals(tp.binding)
      stack_trace = build_stack_trace

      @connection.send_breakpoint_hit(bp.backend_id, {
        captured_at: (Time.now.to_f * 1000).to_i,
        file_path: bp.file_path,
        line_number: bp.line_number,
        stack_trace: stack_trace,
        local_variables: local_variables,
        hit_count: bp.hit_count
      })
    end

    def rate_limit_ok?
      now = Time.now
      if now - @capture_window_start >= 1.0
        @capture_count = 0
        @capture_window_start = now
      end

      if @capture_count >= MAX_CAPTURES_PER_SECOND
        puts "[AIVory Monitor] Rate limit reached, skipping capture" if @config.debug
        return false
      end

      @capture_count += 1
      true
    end

    def capture_locals(binding)
      variables = {}

      binding.local_variables.each do |name|
        next if name.to_s.start_with?("_")

        begin
          value = binding.local_variable_get(name)
          variables[name.to_s] = capture_variable(name.to_s, value, 0)
        rescue StandardError
          # Skip if can't access
        end
      end

      variables
    end

    def capture_variable(name, value, depth)
      result = { name: name, type: value.class.name }

      if depth > @config.max_variable_depth
        result[:value] = "<max depth exceeded>"
        result[:is_truncated] = true
        return result
      end

      if value.nil?
        result[:value] = "nil"
        result[:is_null] = true
      elsif value.is_a?(Numeric) || value.is_a?(TrueClass) || value.is_a?(FalseClass)
        result[:value] = value.to_s
      elsif value.is_a?(String)
        if value.length > 500
          result[:value] = value[0, 500]
          result[:is_truncated] = true
        else
          result[:value] = value
        end
      elsif value.is_a?(Symbol)
        result[:value] = ":#{value}"
      elsif value.is_a?(Array)
        result[:value] = "Array(#{value.size})"
        if depth < @config.max_variable_depth && value.size <= 10
          result[:children] = value.each_with_index.to_h do |v, i|
            ["[#{i}]", capture_variable("[#{i}]", v, depth + 1)]
          end
        end
      elsif value.is_a?(Hash)
        result[:value] = "Hash(#{value.size})"
        if depth < @config.max_variable_depth && value.size <= 10
          result[:children] = value.transform_keys(&:to_s).transform_values do |v|
            capture_variable(v.class.name, v, depth + 1)
          end
        end
      else
        result[:value] = value.class.name
      end

      result
    end

    def build_stack_trace
      caller_locations(3, 50).map do |loc|
        {
          method_name: loc.label,
          file_path: loc.absolute_path || loc.path,
          file_name: loc.path ? File.basename(loc.path) : nil,
          line_number: loc.lineno,
          is_native: (loc.path || "").start_with?("<") || (loc.path || "").include?("/gems/")
        }
      end
    end
  end
end
