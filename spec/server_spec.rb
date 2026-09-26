require 'spec_helper'
require 'debounced/server'
require 'support/server_helpers'

RSpec.describe Debounced::Server do
  include ServerHelpers

  let(:socket_path) { "/tmp/debounced-server-spec-#{Process.pid}.sock" }
  let!(:server_pid) { start_server(socket_path) }

  def client
    @client ||= UNIXSocket.new(socket_path)
  end

  after do
    @client&.close
    stop_server(server_pid)
  end

  it 'publishes the callback once the timeout expires' do
    # given
    write_message(client, debounce_message('key', kwargs: { test_id: 'a' }))
    # when
    message = read_message(client)
    # then
    expect(message).to eq('type' => 'publishEvent',
                          'callback' => { 'class_name' => 'TestEvent', 'method_name' => 'publish1',
                                          'kwargs' => { 'test_id' => 'a' } })
  end

  it 'publishes only the latest callback for a repeated descriptor' do
    # given
    write_message(client, debounce_message('key', kwargs: { test_id: 'first' }))
    write_message(client, debounce_message('key', kwargs: { test_id: 'last' }))
    # when
    messages = [read_message(client), read_message(client, timeout: 0.3)]
    # then
    expect(messages.map { _1&.dig('callback', 'kwargs', 'test_id') }).to eq(['last', nil])
  end

  context 'with several clients connected' do
    let(:other_client) { UNIXSocket.new(socket_path) }

    after { other_client.close }

    it 'keeps callbacks for the same descriptor separate for each client' do
      # given
      write_message(client, debounce_message('key', kwargs: { test_id: 'first' }))
      write_message(other_client, debounce_message('key', kwargs: { test_id: 'other' }))
      # when
      messages = [read_message(client), read_message(other_client)]
      # then
      expect(messages.map { _1&.dig('callback', 'kwargs', 'test_id') }).to eq(%w[first other])
    end

    it 'drops the callback when the requesting client has disconnected' do
      # given
      other_client
      write_message(client, debounce_message('key'))
      client.close
      # when
      message = read_message(other_client, timeout: 0.5)
      # then
      expect(message).to be_nil
    end

    it "discards every client's pending callbacks on reset" do
      # given
      write_message(other_client, debounce_message('key'))
      # when
      write_message(client, type: 'reset')
      # then
      expect(read_message(other_client, timeout: 0.3)).to be_nil
    end
  end

  context 'with timers of different lengths' do
    let(:late_tolerance) { 0.05 }

    it 'fires a shorter timer scheduled after a longer one at its own deadline' do
      # given
      debounce(client, 'long', 1.0)
      sent_at = debounce(client, 'short', 0.1)
      # when
      message = read_message(client)
      # then
      expect([message&.dig('callback', 'kwargs', 'key'), monotonic_now - sent_at])
        .to match(['short', be_between(0.1, 0.1 + late_tolerance)])
    end

    it "keeps firing other clients' timers while one client stops reading" do
      # given
      stuck = UNIXSocket.new(socket_path)
      20.times { |i| write_message(stuck, debounce_message("stuck-#{i}", timeout: 0.05, kwargs: { test_id: 'x' * 100_000 })) }
      sleep 0.3
      sent_at = debounce(client, 'healthy', 0.1)
      # when
      message = read_message(client)
      # then
      expect([message&.dig('callback', 'kwargs', 'key'), monotonic_now - sent_at])
        .to match(['healthy', be_between(0.1, 0.1 + late_tolerance)])
    ensure
      stuck&.close
    end

    it 'never publishes a callback before its timeout' do
      # given
      timeouts = { 'a' => 0.3, 'b' => 0.05, 'c' => 0.2, 'd' => 0.1, 'e' => 0.15 }
      sent_at = timeouts.to_h { |key, timeout| [key, debounce(client, key, timeout)] }
      # when
      callbacks = collect_callbacks(client).value
      # then
      expect(callbacks.map { |key, _, at| at - sent_at.fetch(key) - timeouts.fetch(key) }.min).to be >= 0
    end

    it "delivers each client's descriptors to that client once with its latest payload" do
      # given
      clients = Array.new(3) { UNIXSocket.new(socket_path) }
      collectors = clients.map { |connection| collect_callbacks(connection) }
      expected = {}
      clients.each_with_index do |connection, c|
        6.times do |k|
          key = "client-#{c}-key-#{k}"
          debounce(connection, key, 0.05 * (1 + ((c + k) % 6)))
          debounce(connection, key, 0.05 * (6 - ((c + k) % 6)), seq: 2) if k.even?
          expected[key] = [c, k.even? ? 2 : 1]
        end
      end
      clients.each_with_index { |connection, c| debounce(connection, 'shared', 0.1 * (3 - c), seq: c) }
      # when
      expected = expected.to_a + Array.new(clients.size) { |c| ['shared', [c, c]] }
      received = collectors.each_with_index.flat_map { |collector, c| collector.value.map { |key, seq, _| [key, [c, seq]] } }
      # then
      expect(received.sort).to eq(expected.sort)
    ensure
      clients&.each(&:close)
    end
  end

  it 'discards pending callbacks on reset' do
    # given
    write_message(client, debounce_message('key'))
    # when
    write_message(client, type: 'reset')
    # then
    expect(read_message(client, timeout: 0.3)).to be_nil
  end

  it 'keeps multi-byte characters intact when they arrive split across reads' do
    # given
    bytes = "#{JSON.generate(debounce_message('key', kwargs: { test_id: 'Zoë' }))}\f".b
    split = bytes.index('ë'.b) + 1
    # when
    client.write(bytes.byteslice(0, split))
    sleep 0.05
    client.write(bytes.byteslice(split..))
    # then
    expect(read_message(client).dig('callback', 'kwargs', 'test_id')).to eq('Zoë')
  end

  it 'creates a socket that only its owner can connect to' do
    # when
    mode = File.stat(socket_path).mode & 0o777
    # then
    expect(format('%o', mode)).to eq('600')
  end

  context 'when a stale socket file is left behind' do
    let!(:server_pid) do
      UNIXServer.new(socket_path).close
      spawn_server(socket_path).tap { wait_until_accepting(socket_path) }
    end

    it 'replaces it and serves requests' do
      # given
      write_message(client, debounce_message('key'))
      # when
      message = read_message(client)
      # then
      expect(message&.fetch('type')).to eq('publishEvent')
    end
  end

  context 'when a second server is started on the same socket' do
    let!(:second_server_pid) { spawn_server(socket_path) }

    after { stop_server(second_server_pid) }

    it 'exits with a failure status' do
      # when
      status = exit_status(second_server_pid, within: 3)
      # then
      expect(status&.success?).to be(false)
    end

    it 'leaves the running server reachable after the second one stops' do
      # given
      exit_status(second_server_pid, within: 3)
      stop_server(second_server_pid)
      write_message(client, debounce_message('key'))
      # when
      message = read_message(client)
      # then
      expect(message&.fetch('type')).to eq('publishEvent')
    end
  end

  context 'after SIGTERM' do
    let(:late_tolerance) { 0.05 }

    it 'keeps firing pending timers on schedule' do
      # given
      sent_at = debounce(client, 'pending', 0.3)
      Process.kill('TERM', server_pid)
      # when
      message = read_message(client)
      # then
      expect([message&.dig('callback', 'kwargs', 'key'), monotonic_now - sent_at])
        .to match(['pending', be_between(0.3, 0.3 + late_tolerance)])
    end

    it 'publishes new requests immediately' do
      # given
      debounce(client, 'pending', 1.0)
      Process.kill('TERM', server_pid)
      sleep 0.05
      sent_at = debounce(client, 'late', 1.0)
      # when
      message = read_message(client)
      # then
      expect([message&.dig('callback', 'kwargs', 'key'), monotonic_now - sent_at])
        .to match(['late', be < late_tolerance])
    end

    it 'exits once no timers are pending' do
      # given
      debounce(client, 'pending', 0.2)
      Process.kill('TERM', server_pid)
      read_message(client)
      # when
      status = exit_status(server_pid, within: 1)
      # then
      expect(status&.success?).to be(true)
    end

    it 'exits at once when no timers are pending' do
      # when
      Process.kill('TERM', server_pid)
      # then
      expect(exit_status(server_pid, within: 0.5)&.success?).to be(true)
    end
  end

  it 'removes the socket file when stopped' do
    # when
    stop_server(server_pid, signal: 'TERM')
    # then
    expect(File.exist?(socket_path)).to be(false)
  end
end
