require 'spec_helper'

RSpec.describe Debounced do
  it 'loads concurrent-ruby so ServiceProxy has Concurrent::AtomicBoolean without relying on the host app' do
    # ServiceProxy uses Concurrent::AtomicBoolean at runtime; the gem must require it itself,
    # not lean on Rails/another gem in the host to have loaded it first.
    expect(defined?(Concurrent::AtomicBoolean)).to eq('constant')
  end

  describe '.configure' do
    it 'exposes an error_handler accessor, defaulting to nil' do
      expect(described_class.configuration.error_handler).to be_nil
    end
  end
end
