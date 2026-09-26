# Debounced

Efficient debouncing mechanism for Ruby events. Use it for rate limiting, deduplication, or other 
scenarios where you want to wait for a certain amount of time before processing a given event.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'debounced'
```

And then execute:

```bash
$ bundle install
```

Or install it yourself as:

```bash
$ gem install debounced
```

## Usage

### Configuration

```ruby
# config/initializers/debounced.rb
Debounced.configure do |config|
  config.socket_descriptor = '/tmp/my_app.debounceEvents'
  config.wait_timeout = 3 # idle timeout in seconds for a given activity descriptor
end
```

### Starting the server

Start the debounce server with:

```bash
$ bundle exec rake debounced:server
```

In your Ruby application code:

```ruby
require 'debounced'

# Start a background thread to receive notification that events are ready to be handled after debounce wait is complete
proxy = Debounced::ServiceProxy.new
proxy.listen

# Define your event class; create a helper method that will produce a Debounced::Callback object, which 
# is used to notify the server that the event is ready to be handled
class MyEvent
  attr_reader :test_id

  def initialize(test_id:)
    @test_id = test_id
  end

  def publish
    # put logic here to publish the event after debouncing
    puts "Publishing event: #{inspect}"
  end
  
  def debounce_callback
    Debounced::Callback.new(
      class_name: self.class.name,
      params: { test_id: },
      method_name: 'publish',
      method_params: []
    )
  end
end

event = MyEvent.new({ test_id: "Hello World" })

# request the server to debounce the event, ignoring it if another event with the 
# same descriptor arrives before the timeout
proxy.debounce_activity("my-event-123", 5, event.debounce_callback)
# 2 seconds later
proxy.debounce_activity("my-event-123", 5, event.debounce_callback)
# 4 seconds later
proxy.debounce_activity("my-event-123", 5, event.debounce_callback)
# 5 seconds later the event is published!
# > Publishing event: #<MyEvent:0x00007f9b1b8b3b40 @test_id="Hello World">
```

## How It Works

1. The debounce server listens on a Unix socket and runs one lightweight timer per activity descriptor
2. When you call `debounce_activity`, the proxy sends the descriptor, timeout and callback to the server
3. Each new request for the same descriptor cancels its timer and starts a new one, keeping the latest callback
4. When a timer expires, the server sends the callback back to the proxy, which invokes it

Several processes can connect to one server, for example every Puma worker of an application. Each callback goes
back to the process that sent the latest request for its descriptor, or to another connected process if that one
has gone away. When no server is reachable, the proxy invokes callbacks immediately.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).