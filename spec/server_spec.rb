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
  
  it 'removes the socket file when stopped' do
    # when
    stop_server(server_pid)
    # then
    expect(File.exist?(socket_path)).to be(false)
  end
end
