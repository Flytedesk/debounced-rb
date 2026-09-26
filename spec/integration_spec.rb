require 'spec_helper'
require 'test_event'

RSpec.describe 'Debounced Events', type: :integration do
  DEBOUNCE_TIMEOUT = 1

  def debounce_activity(test_object)
    @service_proxy.debounce_activity(test_object.test_id, DEBOUNCE_TIMEOUT, test_object.debounce_callback)
  end

  def stop_listening
    @event_debouncing_abort_signal.make_true
    sleep Debounced.configuration.wait_timeout
  end

  before :all do
    SemanticLogger.default_level = 'debug'
    Debounced.configuration.wait_timeout = 1
    Debounced.configuration.socket_descriptor = '/tmp/test.debounceEvents'
  end

  before :each do
    @event_handler_invocations = Concurrent::AtomicFixnum.new
    allow_any_instance_of(TestEvent).to receive(:publish1) { @event_handler_invocations.increment }
    allow(TestEvent).to receive(:publish2) { @event_handler_invocations.increment }
  end

  context 'with server running' do
    before :all do
      server_log = File.open('debounce_server.log', 'w')
      @server_pid = Process.spawn(RbConfig.ruby, '-Ilib', '-rdebounced', '-rdebounced/server',
                                  '-e', 'Debounced::Server.new(ARGV[0]).listen',
                                  Debounced.configuration.socket_descriptor,
                                  out: server_log, err: server_log)
      Process.detach(@server_pid)
      sleep 0.5
    end

    before :each do
      @event_debouncing_abort_signal = Concurrent::AtomicBoolean.new
      @service_proxy = Debounced::ServiceProxy.new
      @listening_thread = @service_proxy.listen(@event_debouncing_abort_signal)
      sleep 0.5
    end

    after :each do
      stop_listening
      @listening_thread.exit
      @listening_thread.join(1)
    end

    after :all do
      Process.kill('TERM', @server_pid)
      sleep 0.5
    end

    context 'and debounce = TRUE' do
      context 'and multiple events are published within the debounce window with the same debounce_key' do
        it 'publishes only the last event' do
          # when
          3.times { debounce_activity(TestEvent.new(test_id: 'test')) }
          # then
          sleep DEBOUNCE_TIMEOUT + 1
          stop_listening
          expect(@event_handler_invocations.value).to eq(1)
        end
      end

      context 'and multiple events are published within the debounce window with different debounce_keys' do
        it 'publishes all events' do
          # when
          debounce_activity(TestEvent.new(test_id: 'test1'))
          debounce_activity(TestEvent.new(test_id: 'test2'))
          debounce_activity(TestEvent.new(test_id: 'test3'))
          # then
          sleep DEBOUNCE_TIMEOUT + 1
          stop_listening
          expect(@event_handler_invocations.value).to eq(3)
        end
      end

      context 'and multiple events are published outside the debounce window' do
        it 'publishes all events' do
          # when
          3.times do
            debounce_activity(TestEvent.new(test_id: 'test'))
            sleep DEBOUNCE_TIMEOUT + 1
          end
          # then
          stop_listening
          expect(@event_handler_invocations.value).to eq(3)
        end
      end

      context 'with callbacks on a class method' do
        it 'publishes all events' do
          # given
          callback = Debounced::Callback.new(
            class_name: TestEvent.name,
            method_name: 'publish2',
            args: ['test'],
            )
          # when
          @service_proxy.debounce_activity('test', DEBOUNCE_TIMEOUT, callback)
          # then
          sleep DEBOUNCE_TIMEOUT + 1
          stop_listening
          expect(@event_handler_invocations.value).to eq(1)
        end
      end
    end
  end

  context 'without server running' do
    it 'publishes all events' do
      # given
      @service_proxy = Debounced::ServiceProxy.new
      # when
      3.times { debounce_activity(TestEvent.new(test_id: 'no-server-test')) }
      # then
      expect(@event_handler_invocations.value).to eq(3)
    end
  end
end