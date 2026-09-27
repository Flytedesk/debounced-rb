require 'async'
require 'async/barrier'
require 'async/notification'
require 'async/queue'
require 'io/event'
require 'json'
require 'socket'

module Debounced
  class Server
    def initialize(socket_descriptor)
      @socket_descriptor = socket_descriptor
      @timers = {}
      @writers = Async::Barrier.new
      @queue = IO::Event::Timers.new
      @timer_scheduled = Async::Notification.new
    end

    def listen
      remove_stale_socket_file
      Sync do |task|
        @root = task
        server = bind_owner_only
        logger.info("#{self.class.name} listening on #{@socket_descriptor}")
        task.async { run_timers }
        task.async { drain_on_sigterm }
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
      outbox = Async::Queue.new
      @timers[outbox] = {}
      @writers.async { write_messages(connection, outbox) }
      while (line = connection.gets(ServiceProxy::DELIMITER, chomp: true))
        handle(line, outbox)
      end
    rescue IOError, SystemCallError => e
      logger.warn("Client connection error: #{e.message}")
    ensure
      logger.info('Client disconnected')
      @timers.delete(outbox)&.each_value(&:cancel!)
      outbox.close
      connection.close
      stop_if_drained
    end

    def write_messages(connection, outbox)
      outbox.each { |message| send_message(connection, message) }
    rescue IOError, SystemCallError => e
      logger.warn("Unable to write to client: #{e.message}")
    end

    def handle(line, outbox)
      message = JSON.parse(line)
      case message['type']
      when 'debounceEvent' then debounce(message['data'], outbox)
      when 'reset' then reset
      else logger.warn("Unknown message: #{line}")
      end
    rescue JSON::ParserError => e
      logger.warn("Unable to parse message: #{e.message}")
    end

    def debounce(data, outbox)
      descriptor = data['descriptor']
      timers = @timers.fetch(outbox)
      timers.delete(descriptor)&.cancel!
      if @draining
        publish(descriptor, data['callback'], outbox)
        return stop_if_drained
      end

      logger.debug { "Debouncing #{descriptor}" }
      timers[descriptor] = @queue.after(data['timeout']) do
        timers.delete(descriptor)
        publish(descriptor, data['callback'], outbox)
        stop_if_drained
      end
      @timer_scheduled.signal
    end

    def drain_on_sigterm
      signals, signal_writer = IO.pipe
      Signal.trap('TERM') { signal_writer.write_nonblock('.', exception: false) }
      signals.read(1)
      logger.info('Received SIGTERM; firing pending timers, then exiting')
      @draining = true
      stop_if_drained
    end

    def stop_if_drained
      finish_draining if @draining && @timers.each_value.all?(&:empty?)
    end

    def finish_draining
      @draining = false
      @timers.each_key(&:close)
      @writers.wait
      @root.stop
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

    def publish(descriptor, callback, outbox)
      logger.debug { "Debounce period expired for #{descriptor}" }
      outbox.push(type: 'publishEvent', callback:)
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
