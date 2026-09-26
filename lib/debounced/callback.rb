module Debounced

  ###
  # Represents a callback to be executed by the debounce service
  class Callback
    CORE_RUBY_OWNERS = [BasicObject, Kernel, Object, Module, Class].freeze

    attr_accessor :class_name, :method_name, :args, :kwargs, :method_args, :method_kwargs

    ###
    # @param [String] class_name the name of the class that will receive the callback
    # @param [String] method_name the name of the method that will be called
    # @param [Array] args positional arguments passed to the static method, or to the initializer for instance methods (optional)
    # @param [Hash] kwargs keyword arguments passed to the static method, or to the initializer for instance methods (optional)
    # @param [Array] method_args positional arguments passed to the instance method (optional, ignored for static methods)
    # @param [Hash] method_kwargs keyword arguments passed to the instance method (optional, ignored for static methods)
    #
    # @note if the class implements the method_name as a class method, the message will be sent to the class with args and kwargs.
    # otherwise, an instance of the class will be created using args and kwargs, and the message will be sent to the instance
    # with method_args and method_kwargs.
    #
    # @note args and kwargs values must be JSON-native types (String, Numeric, Boolean, Array, Hash, nil).
    # Symbol values, Date, Time, and other Ruby-specific types will not survive JSON round-trip serialization
    # through the debounce server. Hash keys are deep-symbolized on parse, but values are preserved as-is.
    def initialize(class_name:, method_name:, args: [], kwargs: {}, method_args: [], method_kwargs: {})
      @class_name = class_name.to_s
      @method_name = method_name.to_s
      @args = args
      @kwargs = kwargs
      @method_args = method_args
      @method_kwargs = method_kwargs
    end

    def self.parse(data)
      new(
        class_name: data['class_name'],
        method_name: data['method_name'],
        args: data['args'] || [],
        kwargs: deep_symbolize_keys(data['kwargs'] || {}),
        method_args: data['method_args'] || [],
        method_kwargs: deep_symbolize_keys(data['method_kwargs'] || {}),
      )
    end

    def self.deep_symbolize_keys(object)
      case object
      when Hash
        object.to_h { |key, value| [key.to_sym, deep_symbolize_keys(value)] }
      when Array
        object.map { |item| deep_symbolize_keys(item) }
      else
        object
      end
    end
    private_class_method :deep_symbolize_keys

    def as_json
      {
        class_name:,
        method_name:,
        args:,
        kwargs:,
        method_args:,
        method_kwargs:,
      }
    end

    def call
      Debounced.configuration.logger.debug("Invoking callback #{method_name}")
      klass = callback_class
      if klass.respond_to?(method_name)
        ensure_application_method(klass.method(method_name))
        klass.public_send(method_name, *args, **kwargs)
      else
        ensure_application_method(klass.public_instance_method(method_name))
        klass.new(*args, **kwargs).public_send(method_name, *method_args, **method_kwargs)
      end
    rescue StandardError => e
      Debounced.configuration.logger.warn("Unable to invoke callback #{as_json}: #{e.message}")
      Debounced.configuration.logger.warn(e.backtrace.join("\n"))
    end

    private

    def callback_class
      klass = Object.const_get(class_name)
      return klass if klass.ancestors.include?(Debounced::Callbackable)

      raise ArgumentError, "#{class_name} is not an allowed Debounced callback target. Include Debounced::Callbackable in the class."
    end

    def ensure_application_method(method)
      return unless CORE_RUBY_OWNERS.include?(method.owner)

      raise ArgumentError, "#{method_name} is a core Ruby method and not an allowed Debounced callback"
    end
  end
end