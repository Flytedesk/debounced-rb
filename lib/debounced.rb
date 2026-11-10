require 'debounced/version'
require 'debounced/railtie' if defined?(Rails)
require 'debounced/no_server_error'
require 'debounced/socket_conflict_error'
require 'debounced/service_proxy'
require 'debounced/callbackable'
require 'debounced/callback'
require 'semantic_logger'

module Debounced
  class Error < StandardError; end
  
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end
  end

  class Configuration
    # @!attribute error_handler
    #   Optional callable invoked when a callback raises. Receives the error and the Debounced::Callback.
    #   Lets a host app report callback failures (e.g. to an error tracker) without the gem depending on one.
    attr_accessor :socket_descriptor, :wait_timeout, :enable_trace_logging, :error_handler

    def initialize
      @socket_descriptor = ENV['DEBOUNCED_SOCKET'] || '/tmp/app.debounceEvents'
      @wait_timeout = ENV['DEBOUNCED_TIMEOUT']&.to_i || 3
      @enable_trace_logging = ENV['TRACE_LOGGING'] == 'true'
    end

    def logger
      return @logger if defined? @logger

      SemanticLogger.add_appender(file_name: 'debounced_proxy.log', formatter: :color)
      SemanticLogger.default_level = ENV.fetch('LOG_LEVEL', 'info')
      @logger = SemanticLogger['ServiceProxy']
    end

    def logger=(logger)
      @logger = logger
    end
  end
end