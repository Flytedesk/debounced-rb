require 'async'
require 'json'
require 'socket'

module Debounced
  class Server
    def initialize(socket_descriptor)
      @socket_descriptor = socket_descriptor
      @timers = {}
      @client = nil
    end

    def listen
      remove_socket_file
      Sync do |task|
        @task = task
        server = bind_owner_only
        logger.info("#{self.class.name} listening on #{@socket_descriptor}")
        loop { accept(server.accept) }
      end
    ensure
      remove_socket_file
    end

    private

def bind_owner_only
      previous_umask = File.umask(0o177)
      UNIXServer.new(@socket_descriptor)
    ensure
      File.umask(previous_umask)
    end

    def accept(connection)
      if @client
        reject(connection)
      else
        @client = connection
        @task.async { serve(connection) }
      end
    end

    def reject(connection)
      logger.warn('Rejecting connection: client already connected')
      send_message(connection, type: 'rejectClient')
      connection.close
    end

    def serve(connection)
      logger.info('Client connected')
      while (line = connection.gets(ServiceProxy::DELIMITER, chomp: true))
        handle(line)
      end
    rescue IOError, SystemCallError => e
      logger.warn("Client connection error: #{e.message}")
    ensure
      logger.info('Client disconnected')
      @client = nil
      connection.close
    end

    def handle(line)
      message = JSON.parse(line)
      case message['type']
      when 'debounceEvent' then debounce(message['data'])
      when 'reset' then reset
      else logger.warn("Unknown message: #{line}")
      end
    rescue JSON::ParserError => e
      logger.warn("Unable to parse message: #{e.message}")
    end

    def debounce(data)
      descriptor = data['descriptor']
      @timers.delete(descriptor)&.stop
      logger.debug { "Debouncing #{descriptor}" }
      @timers[descriptor] = @task.async do
        sleep data['timeout']
        @timers.delete(descriptor)
        publish(descriptor, data['callback'])
      end
    end

    def publish(descriptor, callback)
      if @client
        logger.debug { "Debounce period expired for #{descriptor}" }
        send_message(@client, type: 'publishEvent', callback:)
      else
        logger.warn("No client connected; dropping #{descriptor}")
      end
    end

    def reset
      @timers.each_value(&:stop)
      @timers.clear
    end

    def send_message(connection, message)
      connection.write(JSON.generate(message), ServiceProxy::DELIMITER)
    end

    def remove_socket_file
      File.delete(@socket_descriptor) if File.exist?(@socket_descriptor)
    end

    def logger
      Debounced.configuration.logger
    end
  end
end
