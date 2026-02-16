# frozen_string_literal: true

module AIVoryMonitor
  # Data model for captured exceptions.
  class ExceptionData
    attr_accessor :exception_type, :message, :file_path, :line_number,
                  :method_name, :class_name, :severity, :runtime,
                  :runtime_version, :stack_trace, :local_variables,
                  :request_context, :fingerprint

    def initialize
      @runtime = "ruby"
      @runtime_version = RUBY_VERSION
      @stack_trace = []
      @local_variables = nil
      @request_context = nil
    end

    def to_h
      {
        exception_type: @exception_type,
        message: @message,
        file_path: @file_path,
        line_number: @line_number,
        method_name: @method_name,
        class_name: @class_name,
        severity: @severity,
        runtime: @runtime,
        runtime_version: @runtime_version,
        stack_trace: @stack_trace.map(&:to_h),
        local_variables: @local_variables,
        request_context: @request_context,
        fingerprint: @fingerprint
      }
    end
  end

  # Data model for a stack frame.
  class StackFrameData
    attr_accessor :class_name, :method_name, :file_path, :file_name,
                  :line_number, :column_number, :is_native, :local_variables

    def initialize
      @line_number = 0
      @column_number = 0
      @is_native = false
      @local_variables = nil
    end

    def to_h
      {
        class_name: @class_name,
        method_name: @method_name,
        file_path: @file_path,
        file_name: @file_name,
        line_number: @line_number,
        column_number: @column_number,
        is_native: @is_native,
        local_variables: @local_variables&.transform_values(&:to_h)
      }
    end
  end

  # Data model for a captured variable.
  class VariableData
    attr_accessor :name, :type, :value, :is_null, :is_truncated, :children

    def initialize
      @is_null = false
      @is_truncated = false
      @children = nil
    end

    def to_h
      {
        name: @name,
        type: @type,
        value: @value,
        is_null: @is_null,
        is_truncated: @is_truncated,
        children: @children&.transform_values(&:to_h)
      }
    end
  end

  # Data model for captured snapshots.
  class SnapshotData
    attr_accessor :breakpoint_id, :exception_id, :file_path, :line_number,
                  :method_name, :class_name, :stack_trace, :local_variables,
                  :request_context

    def initialize
      @line_number = 0
      @stack_trace = []
      @local_variables = nil
      @request_context = nil
    end

    def to_h
      {
        breakpoint_id: @breakpoint_id,
        exception_id: @exception_id,
        file_path: @file_path,
        line_number: @line_number,
        method_name: @method_name,
        class_name: @class_name,
        stack_trace: @stack_trace.map(&:to_h),
        local_variables: @local_variables&.transform_values(&:to_h),
        request_context: @request_context
      }
    end
  end
end
