# frozen_string_literal: true

module AIVoryMonitor
  # Configuration for the AIVory Monitor agent.
  class Config
    attr_accessor :api_key, :backend_url, :environment, :application_name,
                  :sampling_rate, :max_variable_depth, :debug, :enable_breakpoints,
                  :heartbeat_interval_ms, :max_reconnect_attempts

    def initialize(
      api_key: nil,
      backend_url: nil,
      environment: nil,
      application_name: nil,
      sampling_rate: nil,
      max_variable_depth: nil,
      debug: nil,
      enable_breakpoints: nil,
      heartbeat_interval_ms: nil,
      max_reconnect_attempts: nil
    )
      @api_key = api_key || ENV.fetch("AIVORY_API_KEY", "")
      @backend_url = backend_url || ENV.fetch("AIVORY_BACKEND_URL", "wss://api.aivory.net/monitor/agent")
      @environment = environment || ENV.fetch("AIVORY_ENVIRONMENT", "production")
      @application_name = application_name || ENV["AIVORY_APP_NAME"]
      @sampling_rate = (sampling_rate || ENV.fetch("AIVORY_SAMPLING_RATE", "1.0")).to_f
      @max_variable_depth = (max_variable_depth || ENV.fetch("AIVORY_MAX_DEPTH", "10")).to_i
      @debug = parse_boolean(debug, ENV.fetch("AIVORY_DEBUG", "false"))
      @enable_breakpoints = parse_boolean(enable_breakpoints, ENV.fetch("AIVORY_ENABLE_BREAKPOINTS", "true"))
      @heartbeat_interval_ms = (heartbeat_interval_ms || 30_000).to_i
      @max_reconnect_attempts = (max_reconnect_attempts || 10).to_i
    end

    # Validates the configuration.
    #
    # @raise [ArgumentError] If configuration is invalid
    def validate!
      raise ArgumentError, "AIVORY_API_KEY environment variable is required" if @api_key.nil? || @api_key.empty?

      if @sampling_rate.negative? || @sampling_rate > 1
        raise ArgumentError, "Sampling rate must be between 0.0 and 1.0"
      end

      if @max_variable_depth.negative? || @max_variable_depth > 10
        raise ArgumentError, "Max variable depth must be between 0 and 10"
      end

      true
    end

    # Gets runtime information for the agent.
    #
    # @return [Hash]
    def runtime_info
      {
        runtime: "ruby",
        runtime_version: RUBY_VERSION,
        platform: RUBY_PLATFORM,
        hostname: Socket.gethostname
      }
    end

    private

    def parse_boolean(explicit_value, env_value)
      return explicit_value unless explicit_value.nil?

      env_value.to_s.downcase == "true"
    end
  end
end
