# frozen_string_literal: true

require_relative "aivory_monitor/version"
require_relative "aivory_monitor/config"
require_relative "aivory_monitor/models"
require_relative "aivory_monitor/backend_connection"
require_relative "aivory_monitor/exception_capture"
require_relative "aivory_monitor/trace_manager"

# AIVory Monitor Ruby Agent
#
# Usage:
#   require 'aivory_monitor'
#
#   AIVoryMonitor.init(
#     api_key: 'your-api-key',
#     environment: 'production'
#   )
#
# Or using environment variables:
#   AIVoryMonitor.init  # Uses AIVORY_* environment variables
#
module AIVoryMonitor
  class Error < StandardError; end

  @instance = nil
  @initialized = false
  @mutex = Mutex.new

  class << self
    # Initializes the AIVory Monitor agent.
    #
    # @param api_key [String] API key for authentication
    # @param backend_url [String] WebSocket URL for the backend
    # @param environment [String] Environment name (production, staging, etc.)
    # @param application_name [String, nil] Application name
    # @param sampling_rate [Float] Sampling rate for exceptions (0.0 to 1.0)
    # @param max_variable_depth [Integer] Maximum depth for variable capture
    # @param debug [Boolean] Enable debug logging
    # @param enable_breakpoints [Boolean] Enable non-breaking breakpoints
    def init(
      api_key: nil,
      backend_url: nil,
      environment: nil,
      application_name: nil,
      sampling_rate: nil,
      max_variable_depth: nil,
      debug: nil,
      enable_breakpoints: nil
    )
      @mutex.synchronize do
        if @initialized
          puts "[AIVory Monitor] Agent already initialized"
          return
        end

        config = Config.new(
          api_key: api_key,
          backend_url: backend_url,
          environment: environment,
          application_name: application_name,
          sampling_rate: sampling_rate,
          max_variable_depth: max_variable_depth,
          debug: debug,
          enable_breakpoints: enable_breakpoints
        )

        begin
          config.validate!
        rescue ArgumentError => e
          puts "[AIVory Monitor] Configuration error: #{e.message}"
          return
        end

        puts "[AIVory Monitor] Initializing agent v#{VERSION}"
        puts "[AIVory Monitor] Environment: #{config.environment}"

        @config = config
        @connection = BackendConnection.new(config)
        @exception_capture = ExceptionCapture.new(config, @connection)

        # Install exception handlers
        @exception_capture.install

        # Initialize breakpoint support
        if config.enable_breakpoints
          @trace_manager = TraceManager.new(config, @connection)
          @trace_manager.enable
        end

        # Connect to backend
        @connection.connect

        # Register at_exit handler
        at_exit { shutdown }

        @initialized = true
        puts "[AIVory Monitor] Agent initialized successfully"
      end
    end

    # Manually captures an exception.
    #
    # @param exception [Exception] The exception to capture
    # @param context [Hash, nil] Additional context
    def capture_exception(exception, context = nil)
      return unless @initialized && @exception_capture

      merged_context = (@custom_context || {}).merge(context || {})
      merged_context[:user] = @user if @user

      @exception_capture.capture(exception, merged_context)
    end

    # Sets custom context that will be sent with all captures.
    #
    # @param context [Hash] Context to add
    def set_context(context)
      return unless @initialized

      @custom_context ||= {}
      @custom_context.merge!(context)
    end

    # Sets the current user for context.
    #
    # @param user [Hash] User info with :id, :email, :username keys
    def set_user(user)
      return unless @initialized

      @user = user
    end

    # Shuts down the agent gracefully.
    def shutdown
      @mutex.synchronize do
        return unless @initialized

        puts "[AIVory Monitor] Shutting down agent" if @config&.debug

        @trace_manager&.disable
        @exception_capture&.uninstall
        @connection&.disconnect

        @initialized = false
        @config = nil
        @connection = nil
        @exception_capture = nil
        @trace_manager = nil
      end
    end

    # Checks if the agent is initialized.
    #
    # @return [Boolean]
    def initialized?
      @initialized
    end

    # Checks if connected to the backend.
    #
    # @return [Boolean]
    def connected?
      @initialized && @connection&.connected?
    end

    # Gets the current config (for testing).
    #
    # @return [Config, nil]
    attr_reader :config
  end
end

# Rails integration
if defined?(Rails::Railtie)
  module AIVoryMonitor
    class Railtie < Rails::Railtie
      initializer "aivory_monitor.configure" do |app|
        AIVoryMonitor.init
      end

      config.after_initialize do
        if defined?(ActionController::Base)
          ActionController::Base.class_eval do
            rescue_from Exception do |exception|
              AIVoryMonitor.capture_exception(exception, {
                controller: self.class.name,
                action: action_name,
                params: request.filtered_parameters
              })
              raise exception
            end
          end
        end
      end
    end
  end
end

# Sidekiq integration
if defined?(Sidekiq)
  module AIVoryMonitor
    class SidekiqMiddleware
      def call(worker, job, queue)
        yield
      rescue Exception => e
        AIVoryMonitor.capture_exception(e, {
          worker: worker.class.name,
          queue: queue,
          job_id: job["jid"]
        })
        raise e
      end
    end
  end

  Sidekiq.configure_server do |config|
    config.server_middleware do |chain|
      chain.add AIVoryMonitor::SidekiqMiddleware
    end
  end
end
