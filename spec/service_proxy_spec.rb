require 'spec_helper'
require 'debounced/server'
require 'support/server_helpers'

RSpec.describe Debounced::ServiceProxy do
  include ServerHelpers

  let(:socket_path) { "/tmp/debounced-proxy-spec-#{Process.pid}.sock" }
  let(:logger) { instance_double(SemanticLogger::Logger, debug: nil, info: nil, warn: nil) }
  let!(:server_pid) { start_server(socket_path) }

  before do
    allow(Debounced.configuration).to receive_messages(socket_descriptor: socket_path, logger:)
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
end
