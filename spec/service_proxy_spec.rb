require 'spec_helper'
require 'debounced/server'
require 'support/server_helpers'
require 'test_event'

RSpec.describe Debounced::ServiceProxy do
  include ServerHelpers

  let(:socket_path) { "/tmp/debounced-proxy-spec-#{Process.pid}.sock" }
  let(:logger) { instance_double(SemanticLogger::Logger, debug: nil, info: nil, warn: nil) }
  let!(:server_pid) { start_server(socket_path) }

  before do
    allow(Debounced.configuration).to receive_messages(socket_descriptor: socket_path, logger:, wait_timeout: 0.2)
  end

  after { stop_server(server_pid) }

  it 'does not connect to a socket owned by another user' do
    # given
    allow(File).to receive(:owned?).and_call_original
    allow(File).to receive(:owned?).with(socket_path).and_return(false)
    # when
    described_class.new.reset_server
    # then
    expect(logger).to have_received(:warn).with(/No connection to DebounceEventServer/)
  end
  it 'can be stopped before it starts listening' do
    # when / then
    expect { described_class.new.stop }.not_to raise_error
  end

  it 'lets several proxies listen to the same server' do
    # given
    proxies = Array.new(2) { described_class.new }
    threads = proxies.map(&:listen)
    # when
    sleep 0.5
    # then
    expect(proxies.map(&:listening)).to eq([true, true])
  ensure
    proxies.each(&:stop)
    threads.each { _1.join(1) }
  end
  it 'invokes a callback promptly when it arrives just as an idle read times out' do
    # given
    allow(Debounced.configuration).to receive(:wait_timeout).and_return(1)
    invoked_at = Queue.new
    allow(TestEvent).to receive(:publish2) { invoked_at << Time.now }
    proxy = described_class.new
    thread = proxy.listen
    sleep 0.9
    sent_at = Time.now
    # when
    proxy.debounce_activity('key', 0.2, Debounced::Callback.new(class_name: 'TestEvent', method_name: 'publish2', args: ['x']))
    # then
    expect(invoked_at.pop(timeout: 3) - sent_at).to be < 0.6
  ensure
    proxy.stop
    thread.join(2)
  end
  def invocations(queue, count, within:)
    deadline = Time.now + within
    Array.new(count) { queue.pop(timeout: [deadline - Time.now, 0].max) }.compact
  end

  it 'invokes the callback directly when the connection breaks while sending' do
    # given
    allow(TestEvent).to receive(:publish2)
    proxy = described_class.new
    thread = proxy.listen
    sleep 0.3
    allow_any_instance_of(UNIXSocket).to receive(:write).and_raise(Errno::EPIPE)
    # when
    proxy.debounce_activity('key', 5, Debounced::Callback.new(class_name: 'TestEvent', method_name: 'publish2', args: ['x']))
    # then
    expect(TestEvent).to have_received(:publish2).with('x')
  ensure
    proxy.stop
    thread.join(2)
  end

  context 'when requests are larger than the socket buffer' do
    let(:invoked) { Queue.new }
    let(:padding) { 'x' * 200_000 }
    let(:proxy) { described_class.new }
    let!(:listener) { proxy.listen.tap { sleep 0.3 } }

    before { allow(TestEvent).to receive(:publish2) { |id, _| invoked << id } }

    after do
      proxy.stop
      listener.join(2)
    end

    def debounce(id)
      callback = Debounced::Callback.new(class_name: 'TestEvent', method_name: 'publish2', args: [id, padding])
      proxy.debounce_activity("key-#{id}", 0.2, callback)
    end

    it 'delivers the callback' do
      # when
      debounce(0)
      # then
      expect(invocations(invoked, 1, within: 3)).to eq([0])
    end

    it 'delivers every callback when threads send concurrently' do
      # when
      Array.new(10) { |id| Thread.new { debounce(id) } }.each(&:join)
      # then
      expect(invocations(invoked, 10, within: 5).sort).to eq((0...10).to_a)
    end
  end
  describe '#stop with a timeout' do
    it 'returns at once when not connected to a server' do
      # given
      stop_server(server_pid)
      started = monotonic_now
      # when
      described_class.new.stop(timeout: 5)
      # then
      expect(monotonic_now - started).to be < 0.1
    end

    it 'returns when the server closes the connection' do
      # given
      proxy = described_class.new
      thread = proxy.listen
      sleep 0.3
      other_client = UNIXSocket.new(socket_path)
      debounce(other_client, 'pending', 0.5)
      wait_until_processed(other_client)
      Process.kill('TERM', server_pid)
      started = monotonic_now
      # when
      proxy.stop(timeout: 5)
      elapsed = monotonic_now - started
      server_exit = exit_status(server_pid, within: 0.1)
      # then
      expect(server_exit&.success?).to be(true)
      expect(elapsed).to be < 5
    ensure
      proxy.stop
      thread.join(2)
    end

    it 'returns after the timeout while the server stays connected' do
      # given
      proxy = described_class.new
      thread = proxy.listen
      sleep 0.3
      started = monotonic_now
      # when
      proxy.stop(timeout: 0.3)
      # then
      expect(monotonic_now - started).to be_between(0.3, 0.5)
    ensure
      proxy.stop
      thread.join(2)
    end
  end
end
