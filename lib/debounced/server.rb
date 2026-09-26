require 'async'
require 'async/notification'
require 'io/event'
require 'json'
require 'socket'

module Debounced
  class Server
    def initialize(socket_descriptor)
      @socket_descriptor = socket_descriptor
      @timers = Hash.new { |all, connection| all[connection] = {} }
      @queue = IO::Event::Timers.new
      @timer_scheduled = Async::Notification.new
    end

    def listen
      remove_stale_socket_file
      Sync do |task|
        server = bind_owner_only
        logger.info("#{self.class.name} listening on #{@socket_descriptor}")
        task.async { run_timers }
        loop do
          connection = server.accept
          task.async { serve(connection) }
        end
      ensure
        File.delete(@socket_descriptor) if server
      end
    end

    private

    def bind_owner_only
      previous_umask = File.umask(0o177)
      UNIXServer.new(@socket_descriptor)
    ensure
      File.umask(previous_umask)
    end

    def serve(connection)
      logger.info('Client connected')
      while (line = connection.gets(ServiceProxy::DELIMITER, chomp: true))
        handle(line, connection)
      end
    rescue IOError, SystemCallError => e
      logger.warn("Client connection error: #{e.message}")
    ensure
      logger.info('Client disconnected')
      @timers.delete(connection)&.each_value(&:cancel!)
      connection.close
    end

    def handle(line, connection)
      message = JSON.parse(line)
      case message['type']
      when 'debounceEvent' then debounce(message['data'], connection)
      when 'reset' then reset
      else logger.warn("Unknown message: #{line}")
      end
    rescue JSON::ParserError => e
      logger.warn("Unable to parse message: #{e.message}")
    end

    def debounce(data, connection)
      descriptor = data['descriptor']
      timers = @timers[connection]
      timers.delete(descriptor)&.cancel!
      logger.debug { "Debouncing #{descriptor}" }
      timers[descriptor] = @queue.after(data['timeout']) do
        timers.delete(descriptor)
        publish(descriptor, data['callback'], connection)
      end
      @timer_scheduled.signal
    end

    def run_timers
      loop do
        wait_for_next_deadline
        @queue.fire
      end
    end

    def wait_for_next_deadline
      interval = @queue.wait_interval
      if interval.nil?
        @timer_scheduled.wait
      elsif interval.positive?
        Async::Task.current.with_timeout(interval) { @timer_scheduled.wait }
      end
    rescue Async::TimeoutError
      nil
    end

    def publish(descriptor, callback, connection)
      logger.debug { "Debounce period expired for #{descriptor}" }
      send_message(connection, type: 'publishEvent', callback:)
    rescue IOError, SystemCallError => e
      logger.warn("Unable to publish #{descriptor}: #{e.message}")
    end

    def reset
      @timers.each_value { |timers| timers.each_value(&:cancel!).clear }
    end

    def send_message(connection, message)
      connection.write(JSON.generate(message), ServiceProxy::DELIMITER)
    end

    def remove_stale_socket_file
      return unless File.exist?(@socket_descriptor)

      UNIXSocket.new(@socket_descriptor).close
      raise SocketConflictError, "Another server is listening on #{@socket_descriptor}"
    rescue Errno::ECONNREFUSED
      File.delete(@socket_descriptor)
    end

    def logger
      Debounced.configuration.logger
    end
  end
end
