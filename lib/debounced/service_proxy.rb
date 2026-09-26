require 'socket'
require 'json'

module Debounced
  ###
  # Ruby interface to the debounce service
  # Input is an activity descriptor, and an object.
  # When the activity is debounced, a callback method is invoked on the object.
  # Assumes the object class has an initializer that accepts a hash of attributes, which are the instance variables
  class ServiceProxy
    DELIMITER = "\f".freeze

    attr_reader :logger, :wait_timeout, :listening

    def initialize
      @wait_timeout = Debounced.configuration.wait_timeout
      @logger = Debounced.configuration.logger
      @listening = false
      @mutex = Mutex.new
    end

    ###
    # @param [Concurrent::AtomicBoolean] abort_signal set to true to stop listening for messages
    def listen(abort_signal = nil)
      Thread.new do
        receive(abort_signal)
      end
    end

    ###
    # Send message to server to reset its state. Useful for automated testing.
    def reset_server
      if socket.nil?
        logger.warn("No connection to #{server_name}; unable to reset server.")
      else
        logger_trace { "Resetting #{server_name}" }
        transmit({ type: 'reset' })
      end
    end

    def debounce_activity(activity_descriptor, timeout, callback)
      SemanticLogger.tagged("send") do
        if !listening || socket.nil?
          logger.debug { "No connection to #{server_name}; skipping debounce step." }
          callback.call
        else
          logger_trace { "Sending #{activity_descriptor} to #{server_name}" }
          transmit(build_request(activity_descriptor, timeout, callback))
        end
      end
    end

    ###
    # @param [Concurrent::AtomicBoolean] abort_signal set to true to stop listening for messages
    def receive(abort_signal = nil)
      @abort_signal = abort_signal || Concurrent::AtomicBoolean.new
      SemanticLogger.tagged("receive") do
        logger.info { "Listening for messages from #{server_name}..." }

        loop do
          @listening = true
          break if @abort_signal.true?

          message = receive_message_from_server
          next unless message

          payload = deserialize_message(message)

          instantiate_callback(payload['callback']).call
        rescue Debounced::NoServerError => e
          logger_trace { e.message }
          sleep wait_timeout
        end

        close
      end
    rescue StandardError => e
      logger.warn("Unable to listen for messages from #{server_name}: #{e.message}")
      logger.warn(e.backtrace.join("\n"))
    ensure
      @listening = false
    end

    def stop
      @abort_signal.make_true
    end

    private

    def close
      return unless @socket

      logger.debug("Closing connection to #{server_name}")
      @socket.close
      @socket = nil
    end

    def receive_message_from_server
      raise NoServerError, "#{server_name} at #{socket_descriptor} not running" if socket.nil?

      logger_trace { "Waiting for data from #{server_name}..." }
      message = socket.gets(DELIMITER, chomp: true)
      unless message
        close
        sleep wait_timeout
      end
      message
    rescue IO::TimeoutError
      logger_trace { "Timeout waiting for data" }
      nil
    rescue Errno::EPIPE, IOError, Errno::ECONNRESET
      close
      raise NoServerError, "#{server_name} at #{socket_descriptor} not running"
    end

    def build_request(descriptor, timeout, callback)
      {
        type: 'debounceEvent',
        data: {
          descriptor:,
          timeout:,
          callback: callback.as_json
        }
      }
    end

    def transmit(message)
      socket.send serialize_message(message), 0
    end

    def server_name
      'DebounceEventServer'
    end

    def serialize_message(message)
      "#{JSON.generate(message)}#{DELIMITER}" # inject EOM delimiter (form feed character)
    end

    def deserialize_message(message)
      logger_trace { "Deserializing #{message}" }
      JSON.parse(message)
    end

    def instantiate_callback(data)
      Callback.parse(data)
    end

    def socket_descriptor
      @socket_descriptor ||= Debounced.configuration.socket_descriptor
    end

    def socket
      @mutex.synchronize do
        return @socket if @socket
        return unless File.owned?(socket_descriptor)

        logger_trace { "Connecting to #{server_name} at #{socket_descriptor}" }
        @socket = UNIXSocket.new(socket_descriptor).tap { |s| s.timeout = wait_timeout }
      end
    rescue Errno::ECONNREFUSED, Errno::ENOENT
      ###
      # Errno::ENOENT is raised if the socket file does not exist.
      # Errno::ECONNREFUSED is raised if the socket file exists but no process is listening on it.
      nil
    end

    def logger_trace(&block)
      logger.debug(&block) if Debounced.configuration.enable_trace_logging
    end

  end
end