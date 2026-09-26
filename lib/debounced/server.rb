require 'async'
require 'json'
require 'set'
require 'socket'

module Debounced
  class Server
    def initialize(socket_descriptor)
      @socket_descriptor = socket_descriptor
      @timers = {}
      @clients = Set.new
    end

    def listen
      remove_stale_socket_file
      Sync do |task|
        @task = task
        server = bind_owner_only
        logger.info("#{self.class.name} listening on #{@socket_descriptor}")
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
      @clients << connection
      while (line = connection.gets(ServiceProxy::DELIMITER, chomp: true))
        handle(line, connection)
      end
    rescue IOError, SystemCallError => e
      logger.warn("Client connection error: #{e.message}")
    ensure
      logger.info('Client disconnected')
      @clients.delete(connection)
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
      @timers.delete(descriptor)&.stop
      logger.debug { "Debouncing #{descriptor}" }
      @timers[descriptor] = @task.async do
        sleep data['timeout']
        @timers.delete(descriptor)
        publish(descriptor, data['callback'], connection)
      end
    end

    def publish(descriptor, callback, connection)
      if @clients.include?(connection)
        logger.debug { "Debounce period expired for #{descriptor}" }
        send_message(connection, type: 'publishEvent', callback:)
      else
        logger.warn("Client disconnected; dropping #{descriptor}")
      end
    end

    def reset
      @timers.each_value(&:stop)
      @timers.clear
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
