#!/usr/bin/env ruby
# frozen_string_literal: true

# AIVory Ruby Agent Test Application
#
# Generates various exception types to test exception capture and local variable extraction.
#
# Usage:
#   cd monitor-agents/agent-ruby
#   bundle install
#   AIVORY_API_KEY=test-key-123 AIVORY_BACKEND_URL=ws://localhost:19999/api/monitor/agent/v1 AIVORY_DEBUG=true ruby test_app.rb

require_relative 'lib/aivory_monitor'

class UserContext
  attr_reader :user_id, :email, :active

  def initialize(user_id, email, active: true)
    @user_id = user_id
    @email = email
    @active = active
  end

  def to_s
    "UserContext(user_id='#{user_id}', email='#{email}', active=#{active})"
  end
end

def trigger_exception(iteration)
  # Create some local variables to capture
  test_var = "test-value-#{iteration}"
  count = iteration * 10
  items = %w[apple banana cherry]
  metadata = {
    iteration: iteration,
    timestamp: Time.now.to_i,
    nested: { key: 'value', count: count }
  }
  user = UserContext.new("user-#{iteration}", 'test@example.com')

  case iteration
  when 0
    # NoMethodError (like NullPointerException)
    puts 'Triggering NoMethodError...'
    nil_value = nil
    nil_value.upcase # NoMethodError here

  when 1
    # ArgumentError
    puts 'Triggering ArgumentError...'
    raise ArgumentError, "Invalid argument: test_var=#{test_var}"

  when 2
    # IndexError (like ArrayIndexOutOfBoundsException)
    puts 'Triggering IndexError...'
    arr = [1, 2, 3]
    arr.fetch(10) # IndexError here

  else
    raise RuntimeError, "Unknown iteration: #{iteration}"
  end
end

puts '==========================================='
puts 'AIVory Ruby Agent Test Application'
puts '==========================================='

# Initialize the agent
AIVoryMonitor.init(
  debug: ENV.fetch('AIVORY_DEBUG', 'false').downcase == 'true'
)

# Set user context
AIVoryMonitor.set_user(
  id: 'test-user-001',
  email: 'tester@example.com',
  username: 'tester'
)

# Wait for agent to connect
puts 'Waiting for agent to connect...'
sleep 3
puts "Starting exception tests...\n\n"

# Generate test exceptions
3.times do |i|
  puts "--- Test #{i + 1} ---"
  begin
    trigger_exception(i)
  rescue StandardError => e
    puts "Caught: #{e.class} - #{e.message}"
    # Also manually capture for testing
    AIVoryMonitor.capture_exception(e, { test_iteration: i })
  end
  puts

  sleep 3
end

puts '==========================================='
puts 'Test complete. Check database for exceptions.'
puts '==========================================='

# Keep running briefly to allow final messages to send
sleep 2

# Shutdown cleanly
AIVoryMonitor.shutdown
