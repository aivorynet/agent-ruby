# AIVory Monitor - Ruby Agent

Real-time exception monitoring with AI-powered analysis for Ruby applications. Captures exceptions, stack traces, and local variables with zero performance impact.

## Requirements

- Ruby 2.7 or higher
- Network access to AIVory backend (wss://api.aivory.net)

## Installation

### Using RubyGems

```bash
gem install aivory_monitor
```

### Using Bundler

Add to your `Gemfile`:

```ruby
gem 'aivory_monitor'
```

Then run:

```bash
bundle install
```

## Usage

### Basic Initialization

Initialize the agent at the start of your application:

```ruby
require 'aivory_monitor'

AIVoryMonitor.init(
  api_key: 'your-api-key',
  environment: 'production'
)
```

### Using Environment Variables

Set environment variables and initialize without arguments:

```bash
export AIVORY_API_KEY=your-api-key
export AIVORY_ENVIRONMENT=production
```

```ruby
require 'aivory_monitor'

AIVoryMonitor.init
```

### Manual Exception Capture

Capture exceptions manually with additional context:

```ruby
begin
  risky_operation
rescue => e
  AIVoryMonitor.capture_exception(e, {
    user_id: current_user.id,
    request_id: request.uuid,
    custom_data: { foo: 'bar' }
  })
  raise
end
```

### Setting User Context

Associate exceptions with specific users:

```ruby
AIVoryMonitor.set_user({
  id: user.id,
  email: user.email,
  username: user.username
})
```

### Setting Custom Context

Add persistent context sent with all captures:

```ruby
AIVoryMonitor.set_context({
  version: '1.2.3',
  region: 'us-west-2',
  tenant: 'acme-corp'
})
```

### Rails Integration

The agent automatically integrates with Rails. Add to your `Gemfile`:

```ruby
gem 'aivory_monitor'
```

Create `config/initializers/aivory_monitor.rb`:

```ruby
AIVoryMonitor.init(
  api_key: ENV['AIVORY_API_KEY'],
  environment: Rails.env,
  application_name: 'my-rails-app'
)
```

The agent will automatically capture:
- Controller exceptions with request parameters
- Background job failures (Sidekiq)
- Uncaught exceptions throughout the application

### Sinatra Integration

```ruby
require 'sinatra'
require 'aivory_monitor'

AIVoryMonitor.init(
  api_key: ENV['AIVORY_API_KEY'],
  environment: ENV['RACK_ENV'] || 'development',
  application_name: 'my-sinatra-app'
)

error do
  exception = env['sinatra.error']
  AIVoryMonitor.capture_exception(exception, {
    path: request.path,
    method: request.request_method,
    params: params
  })
  'Internal Server Error'
end

get '/' do
  'Hello World'
end
```

### Rack Middleware

For other Rack-based frameworks:

```ruby
require 'aivory_monitor'

AIVoryMonitor.init

use Rack::Builder do
  use Rack::CommonLogger

  run lambda { |env|
    begin
      # Your application code
      [200, {'Content-Type' => 'text/plain'}, ['OK']]
    rescue => e
      AIVoryMonitor.capture_exception(e, {
        path: env['PATH_INFO'],
        method: env['REQUEST_METHOD']
      })
      raise
    end
  }
end
```

## Configuration

The agent can be configured using environment variables or initialization parameters.

| Environment Variable | Parameter | Description | Default |
|---------------------|-----------|-------------|---------|
| `AIVORY_API_KEY` | `api_key` | API key for authentication | Required |
| `AIVORY_BACKEND_URL` | `backend_url` | Backend WebSocket URL | `wss://api.aivory.net/ws/monitor/agent` |
| `AIVORY_ENVIRONMENT` | `environment` | Environment name (production, staging, etc.) | `production` |
| `AIVORY_APPLICATION_NAME` | `application_name` | Application identifier | Auto-detected |
| `AIVORY_SAMPLING_RATE` | `sampling_rate` | Exception sampling rate (0.0 to 1.0) | `1.0` |
| `AIVORY_MAX_DEPTH` | `max_variable_depth` | Maximum depth for variable capture | `3` |
| `AIVORY_DEBUG` | `debug` | Enable debug logging | `false` |
| `AIVORY_ENABLE_BREAKPOINTS` | `enable_breakpoints` | Enable non-breaking breakpoints | `false` |

### Configuration Example

```ruby
AIVoryMonitor.init(
  api_key: 'your-api-key',
  backend_url: 'wss://api.aivory.net/ws/monitor/agent',
  environment: 'production',
  application_name: 'my-app',
  sampling_rate: 1.0,
  max_variable_depth: 3,
  debug: false,
  enable_breakpoints: true
)
```

## Building from Source

Clone the repository and build the gem:

```bash
git clone https://github.com/aivory/aivory-monitor.git
cd aivory-monitor/monitor-agents/agent-ruby
bundle install
gem build aivory_monitor.gemspec
gem install aivory_monitor-1.0.0.gem
```

### Running Tests

```bash
bundle exec rspec
```

### Linting

```bash
bundle exec rubocop
```

## How It Works

The AIVory Monitor Ruby agent uses standard Ruby exception handling mechanisms to capture runtime errors:

1. **At-Exit Hooks**: Registers an `at_exit` handler to capture unhandled exceptions before the process terminates.

2. **Thread Exception Reporting**: Hooks into `Thread.report_on_exception` to capture exceptions in background threads.

3. **Exception Capture**: When an exception occurs:
   - Captures the full stack trace with file names and line numbers
   - Extracts local variables at each stack frame (up to configured depth)
   - Collects thread information and system context
   - Serializes the data and sends it to the AIVory backend via WebSocket

4. **Non-Breaking Operation**: All capture operations are non-blocking and designed to have minimal performance impact. Failures in the agent never affect your application.

5. **WebSocket Connection**: Maintains a persistent connection to the AIVory backend for real-time exception streaming and bidirectional communication (breakpoint commands, configuration updates).

## Framework Support

### Rails

- Automatic initialization via Railtie
- Controller exception capture with request context
- ActionMailer exception capture
- Works with Rails 5.0+

### Sidekiq

- Automatic middleware injection
- Captures job failures with worker context
- Includes job ID, queue name, and arguments

### Other Frameworks

The agent works with any Ruby application or framework. For frameworks without automatic integration, use manual initialization and exception capture as shown in the usage examples.

## Troubleshooting

### Agent Not Capturing Exceptions

Check that the agent is initialized:

```ruby
puts AIVoryMonitor.initialized?  # Should return true
puts AIVoryMonitor.connected?    # Should return true
```

Enable debug logging:

```ruby
AIVoryMonitor.init(
  api_key: 'your-api-key',
  debug: true
)
```

### Connection Issues

Verify your API key is correct and the backend URL is reachable:

```bash
export AIVORY_DEBUG=true
ruby your_app.rb
```

Check for firewall rules blocking WebSocket connections to `wss://api.aivory.net`.

### High Memory Usage

If capturing large objects causes memory issues, reduce the variable capture depth:

```ruby
AIVoryMonitor.init(
  api_key: 'your-api-key',
  max_variable_depth: 1  # Reduce from default of 3
)
```

Or enable sampling to capture only a percentage of exceptions:

```ruby
AIVoryMonitor.init(
  api_key: 'your-api-key',
  sampling_rate: 0.1  # Capture 10% of exceptions
)
```

### Rails Not Loading Agent

Ensure the gem is in your `Gemfile` and you've run `bundle install`. Create an initializer at `config/initializers/aivory_monitor.rb` to explicitly initialize if needed.

### Sidekiq Jobs Not Being Captured

The Sidekiq middleware is automatically loaded if Sidekiq is detected. Ensure you're loading the agent before Sidekiq workers start:

```ruby
# config/initializers/aivory_monitor.rb
AIVoryMonitor.init
```

## Support

- Documentation: https://aivory.net/monitor/docs
- GitHub Issues: https://github.com/aivory/aivory-monitor/issues
- Email: support@aivory.net

## License

MIT License. See LICENSE file for details.
